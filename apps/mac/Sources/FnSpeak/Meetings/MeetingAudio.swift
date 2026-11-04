import AVFoundation
import CoreAudio
import CoreMedia
import ScreenCaptureKit

/// Has the microphone open and can lend its input to dictation, so a
/// dictation during a meeting doesn't open a second capture of the mic.
protocol MicLender: AnyObject {
    /// `handler` gets 16 kHz mono Float32 buffers on an audio thread.
    func lend(_ handler: @escaping (AVAudioPCMBuffer) -> Void)
    func endLoan()
}

/// Captures both sides of a call for a meeting: the microphone (with echo
/// cancellation, so the far side doesn't land under "Me") and what the Mac
/// plays (via ScreenCaptureKit, audio only). Both come out as 16 kHz mono
/// Float32 and are delivered continuously, silence included, because the
/// core times segments by counting samples per stream.
final class MeetingAudio: NSObject, MicLender {
    enum SystemAudioError: LocalizedError {
        case permissionDenied
        case noDisplay
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Screen Recording permission is off, so only your microphone is recorded."
            case .noDisplay: return "No display to capture system audio from."
            case .failed(let message): return "System audio unavailable: \(message)"
            }
        }
    }

    static let sampleRate = 16_000.0
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// Called on audio threads with 16 kHz mono samples.
    var onSamples: ((AudioSource, [Float]) -> Void)?
    /// Rough level (0…1) per stream, on the main queue.
    var onLevel: ((AudioSource, Float) -> Void)?

    private let mic = AVAudioEngine()
    private var micResampler: Resampler?
    private var stream: SCStream?
    private let systemQueue = DispatchQueue(label: "com.fnspeak.meeting.system-audio", qos: .userInitiated)
    private var systemResampler: Resampler?

    private let lock = NSLock()
    private var loan: ((AVAudioPCMBuffer) -> Void)?
    private var clocks: [AudioSource: StreamClock] = [:]
    /// Streams that have started; only these are topped up with silence.
    private var active: Set<AudioSource> = []
    private var lastLevel: [AudioSource: Date] = [:]
    private var padTimer: DispatchSourceTimer?
    private(set) var isRunning = false
    private(set) var capturesSystemAudio = false

    // MARK: - Start and stop

    /// Starts the microphone. Call `startSystemAudio` afterwards; a meeting
    /// can go on without it.
    func startMic() throws {
        guard !isRunning else { return }
        let start = Date()
        lock.withLock {
            clocks = [.mic: StreamClock(start: start), .system: StreamClock(start: start)]
            active = [.mic]
            lastLevel = [:]
        }

        AudioDevices.apply(selected: Preferences.shared.microphoneId, to: mic)
        let input = mic.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
            // Voice processing ducks other audio by default; the call is that audio.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        } catch {
            Log.error("Meeting: echo cancellation unavailable (\(error.localizedDescription)); recording the mic as is")
        }
        // Voice processing runs input and output together, so the output has to be in the graph.
        _ = mic.mainMixerNode
        mic.mainMixerNode.outputVolume = 0

        let format = input.outputFormat(forBus: 0)
        micResampler = Resampler(from: format)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.handleMic(buffer)
        }
        mic.prepare()
        do {
            try mic.start()
        } catch {
            input.removeTap(onBus: 0)
            try? input.setVoiceProcessingEnabled(false)
            throw error
        }
        isRunning = true
        startPadding()
        AudioRecorder.lender = self
    }

    /// Starts capturing what the Mac plays. Needs Screen Recording permission.
    func startSystemAudio() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw SystemAudioError.permissionDenied
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // Thrown when the permission was revoked or never granted to this build.
            throw SystemAudioError.permissionDenied
        }
        guard let display = content.displays.first else { throw SystemAudioError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Video can't be switched off; keep it as small and slow as allowed.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: systemQueue)
            try await stream.startCapture()
        } catch {
            throw SystemAudioError.failed(error.localizedDescription)
        }
        // The meeting may have ended while capture was starting.
        guard isRunning else {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
        capturesSystemAudio = true
        lock.withLock { _ = active.insert(.system) }
    }

    func stop() {
        AudioRecorder.lender = nil
        lock.withLock { loan = nil }
        padTimer?.cancel()
        padTimer = nil
        if isRunning {
            mic.inputNode.removeTap(onBus: 0)
            mic.stop()
            try? mic.inputNode.setVoiceProcessingEnabled(false)
            mic.reset()
        }
        if let stream {
            stream.stopCapture { _ in }
            self.stream = nil
        }
        // Pad each stream up to now so trailing silence is accounted for.
        flushPadding(force: true)
        lock.withLock { active = [] }
        isRunning = false
        capturesSystemAudio = false
    }

    // MARK: - MicLender

    func lend(_ handler: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.withLock { loan = handler }
    }

    func endLoan() {
        lock.withLock { loan = nil }
    }

    // MARK: - Samples

    private func handleMic(_ buffer: AVAudioPCMBuffer) {
        guard let out = micResampler?.convert(buffer) else { return }
        let borrower = lock.withLock { loan }
        borrower?(out)
        deliver(.mic, out)
    }

    private func handleSystem(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        if systemResampler == nil || systemResampler?.input != pcm.format {
            systemResampler = Resampler(from: pcm.format)
        }
        guard let out = systemResampler?.convert(pcm) else { return }
        deliver(.system, out)
    }

    private func deliver(_ source: AudioSource, _ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        // A gap (the stream paused, or nothing was playing) becomes silence first.
        let gap = lock.withLock { () -> Int in
            guard var clock = clocks[source] else { return 0 }
            let gap = clock.gapBefore(chunk.count)
            clock.fed += gap + chunk.count
            clocks[source] = clock
            return gap
        }
        if gap > 0 { onSamples?(source, [Float](repeating: 0, count: gap)) }
        onSamples?(source, chunk)
        reportLevel(source, chunk)
    }

    private func reportLevel(_ source: AudioSource, _ chunk: [Float]) {
        let now = Date()
        let due = lock.withLock { () -> Bool in
            if let last = lastLevel[source], now.timeIntervalSince(last) < 0.05 { return false }
            lastLevel[source] = now
            return true
        }
        guard due else { return }
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(chunk.count, 1)))
        let level = min(1, rms * 12)
        DispatchQueue.main.async { self.onLevel?(source, level) }
    }

    /// Streams that go quiet (ScreenCaptureKit sends nothing while nothing
    /// plays) are topped up with silence so their clocks keep up.
    private func startPadding() {
        let timer = DispatchSource.makeTimerSource(queue: systemQueue)
        timer.schedule(deadline: .now() + 1, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.flushPadding(force: false) }
        timer.resume()
        padTimer = timer
    }

    private func flushPadding(force: Bool) {
        for source in [AudioSource.mic, .system] {
            let gap = lock.withLock { () -> Int in
                guard active.contains(source), var clock = clocks[source] else { return 0 }
                let gap = force ? clock.behind : clock.stalledGap
                clock.fed += gap
                clocks[source] = clock
                return gap
            }
            if gap > 0 { onSamples?(source, [Float](repeating: 0, count: gap)) }
            if gap > 0, !force { DispatchQueue.main.async { self.onLevel?(source, 0) } }
        }
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    /// Whether some app is capturing from the default input device.
    static var micInUseSomewhere: Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}

extension MeetingAudio: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        handleSystem(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Meeting: system audio stopped (\(error.localizedDescription))")
        DispatchQueue.main.async {
            self.capturesSystemAudio = false
            NotificationCenter.default.post(name: MeetingAudio.systemAudioStopped, object: self)
        }
    }

    static let systemAudioStopped = Notification.Name("MeetingAudioSystemAudioStopped")
}

/// Samples fed so far against what the wall clock says should have been.
private struct StreamClock {
    let start: Date
    var fed = 0

    private var expected: Int { Int(Date().timeIntervalSince(start) * MeetingAudio.sampleRate) }

    /// How far behind the clock the stream is.
    var behind: Int { max(0, expected - fed) }

    /// Silence to insert before a chunk of `count` samples, when the stream
    /// fell more than half a second behind (a pause, not jitter).
    func gapBefore(_ count: Int) -> Int {
        let gap = expected - fed - count
        return gap > Int(MeetingAudio.sampleRate / 2) ? gap : 0
    }

    /// Silence to add when nothing has arrived for over a second.
    var stalledGap: Int {
        let lag = expected - fed
        // Keep a little slack so late-arriving real audio isn't pushed far back.
        return lag > Int(MeetingAudio.sampleRate) ? lag - Int(MeetingAudio.sampleRate / 4) : 0
    }
}

/// Converts any PCM format to 16 kHz mono Float32. Only the first channel is
/// kept: with voice processing on, that's the cleaned-up one, and for system
/// audio the channels are near-identical anyway.
private final class Resampler {
    let input: AVAudioFormat
    private let mono: AVAudioFormat?
    private let converter: AVAudioConverter?

    init(from input: AVAudioFormat) {
        self.input = input
        mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, channels: 1, interleaved: false)
        converter = mono.flatMap { AVAudioConverter(from: $0, to: MeetingAudio.format) }
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let mono, let converter, let channel = firstChannel(of: buffer, as: mono) else { return nil }
        let ratio = MeetingAudio.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: MeetingAudio.format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return channel
        }
        return error == nil ? out : nil
    }

    private func firstChannel(of buffer: AVAudioPCMBuffer, as mono: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = buffer.frameLength
        if let src = buffer.floatChannelData {
            let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
            for i in 0..<frames { dst[i] = src[0][i * stride] }
        } else if let src = buffer.int16ChannelData {
            let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
            for i in 0..<frames { dst[i] = Float(src[0][i * stride]) / Float(Int16.max) }
        } else {
            return nil
        }
        return out
    }
}
