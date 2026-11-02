import SwiftUI

struct DictationTab: View {
    @ObservedObject var prefs = Preferences.shared
    @StateObject private var meter = MicLevelMeter()
    @State private var inputs = AudioDevices.inputs()
    @State private var micGranted = AudioRecorder.hasPermission

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
                Toggle("Stop after a pause in speech", isOn: $prefs.autoStopEnabled)
                if prefs.autoStopEnabled {
                    LabeledContent("Silence before stopping") {
                        HStack {
                            Slider(value: $prefs.autoStopSeconds, in: 1...10, step: 0.5)
                                .frame(width: 160)
                            Text("\(prefs.autoStopSeconds, specifier: "%.1f") s")
                                .monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                Text("**⌃⌥Z** right after a dictation swaps it for exactly what you said.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Microphone") {
                Picker("Input", selection: $prefs.microphoneId) {
                    Text("System default").tag("")
                    ForEach(choices) { Text($0.name).tag($0.id) }
                }
                if micGranted {
                    LabeledContent("Level") { LevelMeterBar(level: meter.level) }
                } else {
                    HStack {
                        Text("Microphone access is off.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Allow") {
                            AudioRecorder.requestPermission {
                                micGranted = $0
                                meter.start()
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            inputs = AudioDevices.inputs()
            micGranted = AudioRecorder.hasPermission
            meter.start()
        }
        .onDisappear { meter.stop() }
        .onChange(of: prefs.microphoneId) { meter.restart() }
    }

    /// Connected inputs, plus the saved one if it has been unplugged.
    private var choices: [AudioInput] {
        let saved = prefs.microphoneId
        if saved.isEmpty || inputs.contains(where: { $0.id == saved }) { return inputs }
        return inputs + [AudioInput(id: saved, name: "Disconnected microphone")]
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

private struct LevelMeterBar: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(level > 0.85 ? Color.orange : Color.green)
                    .frame(width: max(4, proxy.size.width * CGFloat(level)))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(width: 180, height: 6)
    }
}
