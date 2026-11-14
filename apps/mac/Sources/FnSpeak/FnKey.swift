import AppKit
import Foundation

/// What macOS does when Fn (the Globe key) is tapped by itself, from
/// System Settings → Keyboard → "Press 🌐 key to".
///
/// With Fn as the dictation key, a tap would also open the emoji picker,
/// which then takes the dictated text. The system decides that below
/// anything an app can intercept, so the only thing that stops it is the
/// setting itself. While FnSpeak runs with Fn as its key it holds the
/// setting at Do Nothing, and puts back what was there when it quits.
enum FnKeySetting {
    /// 0 Do Nothing, 1 Change Input Source, 2 Show Emoji & Symbols, 3 Start Dictation.
    private static let doNothing: Int32 = 0
    /// What the setting was before FnSpeak took it, kept on disk so a crash
    /// can't lose it: the next launch still knows what to put back.
    private static let savedKey = "fnKeyUsageBeforeFnSpeak"

    private static let toolbox = dlopen("/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox", RTLD_NOW)

    /// The setting in force right now, or nil if this macOS won't say.
    static var current: Int32? {
        if let symbol = dlsym(toolbox, "TISGetFnUsageType") {
            return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)()
        }
        return (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? NSNumber)?.int32Value
    }

    /// True unless a tap of Fn does nothing of the system's own.
    static var doesSomethingElse: Bool { current != doNothing }

    /// FnSpeak is holding the setting at Do Nothing.
    static var isHeld: Bool { UserDefaults.standard.object(forKey: savedKey) != nil }

    /// Apple's own setter, the one the Keyboard pane uses, so the change
    /// takes effect at once. It isn't public; without it there is nothing
    /// that works live, and the user is pointed at System Settings instead.
    private static func set(_ value: Int32) -> Bool {
        guard let symbol = dlsym(toolbox, "TISUpdateFnUsageType") else { return false }
        unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)(value)
        return current == value
    }

    /// Hold or hand back the setting to match how FnSpeak is set up. Called
    /// at launch and whenever the hotkey, the switch for this, or pause changes.
    static func sync() {
        let prefs = Preferences.shared
        let wanted = prefs.keepFnKey && prefs.hotkey.keyCode == Hotkey.fn.keyCode && prefs.hotkey.isModifierOnly && !prefs.paused
        wanted ? hold() : release()
    }

    /// This copy of the app is the one holding it. A second copy (a test
    /// build, a snapshot run) must not hand back what the first is using.
    private static var mine = false

    private static func hold() {
        guard let now = current else { return }
        if now == doNothing {
            // Already off. If a saved value is waiting, an earlier run was
            // cut short while holding it: carry on, and put it back on quit.
            if isHeld { mine = true }
            return
        }
        // Remember only the first value seen, which is the user's own choice.
        if !isHeld { UserDefaults.standard.set(Int(now), forKey: savedKey) }
        if set(doNothing) {
            mine = true
            Log.info("Fn key: holding the system's Globe key action off while FnSpeak runs")
        } else {
            UserDefaults.standard.removeObject(forKey: savedKey)
            Log.error("Fn key: couldn't switch off the system's Globe key action")
        }
    }

    /// Put back what the user had. Safe to call when nothing is held.
    static func release() {
        guard mine, let saved = UserDefaults.standard.object(forKey: savedKey) as? Int else { return }
        mine = false
        UserDefaults.standard.removeObject(forKey: savedKey)
        // Only if it's still as FnSpeak left it; a change made in System
        // Settings since then is the user's and stays.
        if current == doNothing, set(Int32(saved)) {
            Log.info("Fn key: gave the Globe key back its system action")
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
