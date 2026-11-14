import SwiftUI

/// The hotkey picker, shared by the Dictation tab and onboarding: a preset
/// list, the recorder for a custom key, and how a press behaves.
struct HotkeyChooser: View {
    @ObservedObject var prefs = Preferences.shared
    @State private var fnDoesSomethingElse = FnKeySetting.doesSomethingElse

    var body: some View {
        KitPicker("Dictate with", selection: $prefs.hotkeyPreset, width: 230) {
            ForEach(HotkeyPreset.allCases) { Text($0.label).tag($0.rawValue) }
        }
        if prefs.hotkeyPreset == HotkeyPreset.custom.rawValue {
            LabeledContent("Shortcut") {
                HotkeyRecorder(hotkey: prefs.customHotkey) { prefs.customHotkey = $0 }
            }
        }
        if prefs.hotkeyPreset == HotkeyPreset.fn.rawValue, fnDoesSomethingElse {
            // macOS acts on a tap of Fn by itself (the emoji picker, by
            // default), which then takes the dictated text. Only the user
            // can turn that off.
            VStack(alignment: .leading, spacing: 6) {
                Label("macOS also uses a tap of Fn, usually to open the emoji picker. It gets in the way of double-tapping and can swallow what you dictate.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("In Keyboard settings, set \"Press 🌐 key to\" to Do Nothing.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Keyboard Settings") { FnKeySetting.openSettings() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                fnDoesSomethingElse = FnKeySetting.doesSomethingElse
            }
        }

        KitPicker("Behavior", selection: $prefs.triggerStyle, width: 230) {
            Text("Hold to talk").tag("hold")
            Text("Press to start, press to stop").tag("toggle")
            Text("Both").tag("both")
        }
        Text(styleHelp).font(.callout).foregroundStyle(.secondary)
    }

    private var styleHelp: String {
        let key = prefs.hotkey.displayName
        switch prefs.triggerStyle {
        case "hold": return "Hold \(key) while you talk and let go to finish."
        case "toggle": return "Press \(key) to start and press it again to finish."
        default: return "Hold \(key) to talk. Double-tap it for hands-free, then press it again to finish."
        }
    }
}

/// What macOS does when Fn (the Globe key) is tapped by itself, from
/// System Settings → Keyboard → "Press 🌐 key to".
enum FnKeySetting {
    /// True unless it's set to Do Nothing. Unset means the system default,
    /// which is the emoji picker or switching input source.
    static var doesSomethingElse: Bool {
        let value = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        return value != 0
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
