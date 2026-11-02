import SwiftUI

struct CleanupTab: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController
    @State private var apiKey = ""

    var body: some View {
        Form {
            Picker("Cleanup", selection: $prefs.mode) {
                Text("Local model").tag("local")
                Text("Cloud").tag("cloud")
                Text("Filter only (instant, no rewriting)").tag("filterOnly")
                Text("Raw (exactly what you said)").tag("raw")
            }
            .onChange(of: prefs.mode) { engine.reconfigureCleanup() }

            switch prefs.mode {
            case "local":
                Section("Local model") {
                    LabeledContent("Model", value: ModelLocator.cleanupModel?.lastPathComponent ?? "None found")
                    LabeledContent("llama-server", value: ModelLocator.llamaServer?.path ?? "Not found")
                    Text("A 3–4B model handles fillers and most corrections. Slower machines may prefer Cloud or Filter only.")
                        .foregroundStyle(.secondary)
                }
            case "cloud":
                Section("Cloud") {
                    Text("Only text is sent: the transcript, matching vocabulary and a little on-screen context. Your voice never leaves this Mac.")
                        .foregroundStyle(.secondary)
                    Picker("Provider", selection: $prefs.cloudProvider) {
                        ForEach(Preferences.CloudProviderChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: prefs.cloudProvider) {
                        prefs.applyProviderDefaults()
                        apiKey = prefs.apiKey ?? ""
                    }
                    if prefs.cloudProvider == .custom {
                        TextField("Base URL", text: $prefs.customBaseURL)
                    }
                    SecureField("API key", text: $apiKey)
                    TextField("Model for corrections", text: $prefs.cloudModel)
                    TextField("Model for everything else", text: $prefs.cloudLightModel)
                    Button("Save") {
                        prefs.apiKey = apiKey
                        engine.reconfigureCleanup()
                    }
                }
            default:
                EmptyView()
            }

            if let warning = engine.cleanupWarning {
                Section { Text(warning).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .onAppear { apiKey = prefs.apiKey ?? "" }
    }
}
