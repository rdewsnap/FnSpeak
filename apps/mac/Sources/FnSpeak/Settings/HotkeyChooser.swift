import SwiftUI

/// The hotkey picker, shared by the Dictation tab and onboarding: a preset
/// list, the recorder for a custom key, and how a press behaves.
struct HotkeyChooser: View {
    @ObservedObject var prefs = Preferences.shared
    private var fnDoesSomethingElse: Bool { FnKeySetting.doesSomethingElse }

    var body: some View {
        KitPicker("Dictate with", selection: $prefs.hotkeyPreset, width: 230) {
            ForEach(HotkeyPreset.allCases) { Text($0.label).tag($0.rawValue) }
        }
        if prefs.hotkeyPreset == HotkeyPreset.custom.rawValue {
            LabeledContent("Shortcut") {
                HotkeyRecorder(hotkey: prefs.customHotkey) { prefs.customHotkey = $0 }
            }
        }
        if prefs.hotkeyPreset == HotkeyPreset.fn.rawValue {
            Toggle("Keep Fn for dictation", isOn: $prefs.keepFnKey)
            if prefs.keepFnKey {
                Text("While FnSpeak is running, a tap of Fn won't open the emoji picker or switch keyboards. Quit FnSpeak and Fn goes back to what it did.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if fnDoesSomethingElse {
                // macOS acts on a tap of Fn by itself, and the picker it
                // opens then takes the dictated text.
                VStack(alignment: .leading, spacing: 6) {
                    Label("macOS also uses a tap of Fn, usually to open the emoji picker. It gets in the way of double-tapping and can swallow what you dictate.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Keyboard Settings") { FnKeySetting.openSettings() }
                }
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

