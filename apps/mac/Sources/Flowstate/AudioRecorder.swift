import AVFoundation

/// Captures the microphone as 16 kHz mono Float32, the format every speech
/// engine in the core expects. Audio is kept in memory only.
final class AudioRecorder {
    /// How much new audio to collect before handing it to `onChunk` (250 ms).
    static let chunkSamples = 4_000

    /// Rough input level (0…1) for the overlay, called on the main queue.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    /// What's been handed to `onChunk` so far, and the handler itself.
    private var emitted = 0
    private var onChunk: (([Float]) -> Void)?
    private let lock = NSLock()
    private(set) var isRecording = false
    private var appliedMicrophone = ""
    /// Set while a meeting has the mic open; dictation then reads from its tap.
    static var lender: MicLender?
    private var borrowing = false

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Start recording. `onChunk` gets the audio as it arrives, about every
    /// 250 ms and once more with the rest on `stop()`, in order. It's called
    /// on the audio thread, so it should only hand the samples off.
    func start(onChunk: (([Float]) -> Void)? = nil) throws {
        guard !isRecording else { return }
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            emitted = 0
            self.onChunk = onChunk
        }
        if let lender = Self.lender {
            converter = AVAudioConverter(from: target, to: target)
            lender.lend { [weak self] in self?.append($0) }
            borrowing = true
            isRecording = true
            return
        }

        let microphone = Preferences.shared.microphoneId
        if microphone != appliedMicrophone {
            engine.reset()
            appliedMicrophone = microphone
        }
        AudioDevices.apply(selected: microphone, to: engine)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: format, to: target)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stop and return everything recorded since `start()`.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        if borrowing {
            Self.lender?.endLoan()
            borrowing = false
        } else {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        isRecording = false
        return lock.withLock {
            emitChunk(force: true)
            onChunk = nil
            return samples
        }
    }

    /// Hand new audio to `onChunk`. Called with `lock` held, which keeps the
    /// chunks in order.
    private func emitChunk(force: Bool) {
        guard let onChunk, samples.count > emitted, force || samples.count - emitted >= Self.chunkSamples else { return }
        onChunk(Array(samples[emitted...]))
        emitted = samples.count
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
        lock.withLock {
            samples.append(contentsOf: chunk)
            emitChunk(force: false)
        }

        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(chunk.count, 1)))
        let level = min(1, rms * 12)
        DispatchQueue.main.async { self.onLevel?(level) }
    }
}
