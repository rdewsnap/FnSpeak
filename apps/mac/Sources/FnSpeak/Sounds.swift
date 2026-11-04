import AppKit

/// Quiet system sounds for start and stop, if enabled.
enum Sounds {
    static func start() { play("Tink") }
    static func stop() { play("Pop") }

    private static func play(_ name: String) {
        guard Preferences.shared.soundsEnabled, let sound = NSSound(named: name) else { return }
        sound.volume = 0.35
        sound.stop()
        sound.play()
    }
}
