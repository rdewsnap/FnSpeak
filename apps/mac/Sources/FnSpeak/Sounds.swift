import AppKit

/// The short sounds played when dictation starts and stops, if enabled.
/// They are the ones macOS ships, so there is nothing to bundle.
enum Sounds {
    /// What the pickers offer: the gentler system sounds, shortest first.
    static let choices = ["Tink", "Pop", "Bottle", "Purr", "Morse", "Ping", "Glass", "Frog", "Funk", "Submarine", "Blow", "Hero"]
    /// A choice that plays nothing, for a sound at one end only.
    static let none = "None"
    static let defaultStart = "Tink"
    static let defaultStop = "Pop"

    static func start() {
        if Preferences.shared.soundsEnabled { play(Preferences.shared.startSound) }
    }

    static func stop() {
        if Preferences.shared.soundsEnabled { play(Preferences.shared.stopSound) }
    }

    /// Plays a sound by name whether or not sounds are on, so a picker can
    /// let you hear a choice.
    static func play(_ name: String) {
        guard name != none, let sound = NSSound(named: name) else { return }
        sound.volume = Float(Preferences.shared.soundVolume)
        sound.stop()
        sound.play()
    }
}
