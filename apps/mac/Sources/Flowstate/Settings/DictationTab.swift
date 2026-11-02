import SwiftUI

struct DictationTab: View {
    @ObservedObject var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Hotkey") {
                Picker("Dictate with", selection: $prefs.hotkeyPreset) {
                    ForEach(HotkeyPreset.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if prefs.hotkeyPreset == HotkeyPreset.custom.rawValue {
                    LabeledContent("Shortcut") {
                        HotkeyRecorder(hotkey: prefs.customHotkey) { prefs.customHotkey = $0 }
                    }
                }
                if prefs.hotkeyPreset == HotkeyPreset.fn.rawValue {
                    Text("If Fn opens the emoji picker, set System Settings → Keyboard → \"Press 🌐 key to\" → Do Nothing.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Picker("Behavior", selection: $prefs.triggerStyle) {
                    Text("Hold to talk").tag("hold")
                    Text("Press to start, press to stop").tag("toggle")
                    Text("Both").tag("both")
                }
                Text(styleHelp).font(.callout).foregroundStyle(.secondary)
            }

            Section("While recording") {
                Toggle("Press Esc to cancel", isOn: $prefs.escapeCancels)
                Text("**⌃⌥Z** right after a dictation swaps it for exactly what you said.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
