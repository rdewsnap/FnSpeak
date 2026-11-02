import ServiceManagement
import SwiftUI

struct GeneralTab: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Status") {
                switch engine.status {
                case .loading: Text("Loading the speech model…").foregroundStyle(.secondary)
                case .ready: Text("Ready").foregroundStyle(.secondary)
                case .failed(let message): Text(message).foregroundStyle(.red)
                }
            }

            Section("Startup") {
                Toggle("Open Flowstate at login", isOn: loginBinding)
                if LaunchAtLogin.status == .requiresApproval {
                    HStack {
                        Text("Approve Flowstate in System Settings → Login Items.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(.orange)
                }
            }

            Section("Appearance") {
                Toggle("Show in menu bar", isOn: Binding(
                    get: { prefs.showInMenuBar },
                    set: { prefs.showInMenuBar = $0; if !$0 { prefs.showInDock = true } }
                ))
                Toggle("Show in Dock", isOn: Binding(
                    get: { prefs.showInDock },
                    set: { prefs.showInDock = $0; if !$0 { prefs.showInMenuBar = true } }
                ))
                Text("One of the two stays on so you can always get back to Flowstate.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Feedback") {
                Toggle("Play a sound when dictation starts and stops", isOn: $prefs.soundsEnabled)
            }

            Section("Updates") {
                LabeledContent("Version", value: AppInfo.version)
                Link("See the latest release on GitHub", destination: AppInfo.releasesURL)
            }
        }
        .formStyle(.grouped)
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
                    loginError = "Couldn't change the login item. This only works from the installed Flowstate.app."
                }
                launchAtLogin = LaunchAtLogin.isEnabled
            }
        )
    }
}
