import ServiceManagement
import SwiftUI

struct GeneralTab: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController

    @ObservedObject private var updates = UpdateChecker.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    var body: some View {
        KitForm {
            if case .failed(let message) = engine.status {
                KitSection(title: "Status") { Text(message).foregroundStyle(.red) }
            }

            KitSection(title: "Startup") {
                Toggle("Open FnSpeak at login", isOn: loginBinding)
                if LaunchAtLogin.status == .requiresApproval {
                    HStack {
                        Text("Approve FnSpeak in System Settings → Login Items.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(.orange)
                }
            }

            KitSection(title: "Appearance") {
                Toggle("Show in menu bar", isOn: Binding(
                    get: { prefs.showInMenuBar },
                    set: { prefs.showInMenuBar = $0; if !$0 { prefs.showInDock = true } }
                ))
                Toggle("Show in Dock", isOn: Binding(
                    get: { prefs.showInDock },
                    set: { prefs.showInDock = $0; if !$0 { prefs.showInMenuBar = true } }
                ))
                Text("One of the two stays on so you can always get back to FnSpeak.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            KitSection(title: "Overlay") {
                KitPicker("Position", selection: $prefs.overlayPosition) {
                    Text("Bottom center").tag("bottom")
                    Text("Top center").tag("top")
                    Text("Near the pointer").tag("cursor")
                    Text("Hidden").tag("hidden")
                }
                KitPicker("Size", selection: $prefs.overlaySize) {
                    Text("Small").tag("small")
                    Text("Medium").tag("medium")
                    Text("Large").tag("large")
                }
                Toggle("Show pill when idle", isOn: $prefs.showPillWhenIdle)
                    .disabled(prefs.overlayPosition == "hidden")
                if prefs.overlayPosition == "hidden" {
                    Text("Errors and notes still appear so a failed dictation is never silent.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if prefs.showPillWhenIdle {
                    Text("A small pill stays on screen. Hover it to see the hotkey; click it to open the notes bar.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            KitSection(title: "Feedback") {
                Toggle("Play a sound when dictation starts and stops", isOn: $prefs.soundsEnabled)
                if prefs.soundsEnabled {
                    soundPicker("When it starts", selection: $prefs.startSound)
                    soundPicker("When it stops", selection: $prefs.stopSound)
                    LabeledContent("Volume") {
                        Slider(value: $prefs.soundVolume, in: 0.05...1) { editing in
                            if !editing { Sounds.play(prefs.startSound) }
                        }
                        .frame(width: 180)
                    }
                }
            }

            KitSection(title: "Updates") {
                LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                HStack {
                    Button("Check for Updates") { updates.check() }
                        .disabled(updates.state == .checking)
                    switch updates.state {
                    case .idle: EmptyView()
                    case .checking: ProgressView().controlSize(.small)
                    case .current: Text("You're up to date.").foregroundStyle(.secondary)
                    case .available(let version, let page):
                        Text("FnSpeak \(version) is out.")
                        Link("Get it", destination: page)
                    case .failed(let message): Text(message).foregroundStyle(.orange).lineLimit(2)
                    }
                }
                Text("FnSpeak only checks when you ask. The check is one request to GitHub.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enabled in
                do {
                    try LaunchAtLogin.set(enabled)
                    loginError = nil
                } catch {
                    loginError = "Couldn't change the login item. This only works from the installed FnSpeak.app."
                }
                launchAtLogin = LaunchAtLogin.isEnabled
            }
        )
    }

    /// A sound menu that plays each choice as it's picked.
    private func soundPicker(_ title: String, selection: Binding<String>) -> some View {
        let heard = Binding(get: { selection.wrappedValue }, set: { selection.wrappedValue = $0; Sounds.play($0) })
        return KitPicker(title, selection: heard) {
            ForEach(Sounds.choices, id: \.self) { Text($0).tag($0) }
            Divider()
            Text(Sounds.none).tag(Sounds.none)
        }
    }
}
