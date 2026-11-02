import SwiftUI

struct DictationTab: View {
    @ObservedObject var prefs = Preferences.shared
    @StateObject private var meter = MicLevelMeter()
    @State private var inputs = AudioDevices.inputs()
    @State private var micGranted = AudioRecorder.hasPermission

    var body: some View {
        Form {
            Section("Hotkey") {
                HotkeyChooser(prefs: prefs)
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

            Section("Spoken commands") {
                Text("End a dictation with **scratch that** to drop the last sentence, or **new line** / **new paragraph** to add a break after the text. Pause before a command; in the middle of a sentence the words are typed as usual.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Press Return when a dictation ends with “send it”", isOn: $prefs.allowSendCommand)
                Text("“Send it” or “send that” after a pause inserts the text, then presses Return. In chat apps that sends the message right away, so it's off unless you want it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
