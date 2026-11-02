import AVFoundation
import CoreAudio

struct AudioInput: Identifiable, Hashable {
    /// The device's unique id, stable across reconnects.
    let id: String
    let name: String
}

enum AudioDevices {
    static func inputs() -> [AudioInput] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices
            .map { AudioInput(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Points the engine's input at the chosen microphone. An empty id, or a
    /// microphone that is no longer connected, leaves the system default.
    static func apply(selected uid: String, to engine: AVAudioEngine) {
        guard !uid.isEmpty, var device = deviceID(forUID: uid), let unit = engine.inputNode.audioUnit else { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &device, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var cfUID = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &device)
        }
        return status == noErr && device != 0 ? device : nil
    }
}

/// Live input level for the settings preview. Audio is measured and dropped.
final class MicLevelMeter: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var running = false

    private let engine = AVAudioEngine()

    func start() {
        guard !running, AudioRecorder.hasPermission else { return }
        AudioDevices.apply(selected: Preferences.shared.microphoneId, to: engine)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<count { sum += data[i] * data[i] }
            let level = min(1, sqrt(sum / Float(max(count, 1))) * 12)
            DispatchQueue.main.async { self?.level = level }
        }
        engine.prepare()
        do {
            try engine.start()
            running = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        level = 0
    }

    func restart() {
        stop()
        engine.reset()
        start()
    }
}
