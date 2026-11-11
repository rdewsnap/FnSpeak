import SwiftUI

struct CleanupTab: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController

    @State private var apiKey = ""
    @State private var hardware: Hardware?
    @State private var testing = false
    @State private var testResult: CloudConnectionTest.Outcome?
    @State private var keptWords: [String] = []
    @AppStorage(ModelLocator.cleanupModelKey) private var cleanupModel = ""
    @ObservedObject private var account = AccountController.shared

    var body: some View {
        Form {
            Section("Mode") {
                Picker("Cleanup", selection: $prefs.mode) {
                    Text("Local model").tag("local")
                    Text("Cloud").tag("cloud")
                    Text("Filter only").tag("filterOnly")
                    Text("Raw").tag("raw")
                }
                .onChange(of: prefs.mode) {
                    testResult = nil
                    engine.reconfigureCleanup()
                }
                Text(explanation).font(.callout).foregroundStyle(.secondary)
                if let hardware {
                    Label(recommendation(hardware), systemImage: "sparkles")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if prefs.mode == "local" {
                Section("Local model") {
                    let models = ModelLocator.cleanupModelCandidates
                    if models.count > 1 {
                        Picker("Model", selection: $cleanupModel) {
                            Text("Automatic (\(ModelLocator.automaticCleanupModelName))").tag("")
                            ForEach(models, id: \.lastPathComponent) { Text($0.lastPathComponent).tag($0.lastPathComponent) }
                        }
                        .onChange(of: cleanupModel) { engine.reconfigureCleanup() }
                    } else {
                        LabeledContent("Model", value: models.first?.lastPathComponent ?? "None found")
                    }
                    LabeledContent("llama-server", value: ModelLocator.llamaServer?.path ?? "Not found")
                }
            }

            if prefs.mode == "cloud" { cloudSection }

            Section("Writing style") {
                ForEach(AppCategory.allCases) { category in
                    Picker(category.label, selection: styleBinding(for: category)) {
                        ForEach(WritingStyle.allCases) { Text("\($0.label) — \($0.detail)").tag($0) }
                    }
                }
                Text("Used by the cleanup model in local and cloud modes. Apps outside these lists get a style picked from the app and the page you're on.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Style overrides by app") {
                if prefs.styleOverrides.isEmpty {
                    Text("Apps without an override use their category's style.").foregroundStyle(.secondary)
                }
                ForEach(prefs.styleOverrides.keys.sorted(), id: \.self) { bundleId in
                    HStack {
                        AppLabel(bundleId: bundleId)
                        Spacer()
                        Picker("", selection: overrideBinding(bundleId)) {
                            ForEach(WritingStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Button { prefs.styleOverrides[bundleId] = nil } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                AddAppMenu(title: "Add app…", excluding: Set(prefs.styleOverrides.keys)) {
                    prefs.styleOverrides[$0] = (AppCategory.of($0)?.defaultStyle ?? .prose).rawValue
                }
            }

            Section("Words that always pass through") {
                if keptWords.isEmpty {
                    Text("Words you add by hand in Vocabulary are spelled exactly as written.").foregroundStyle(.secondary)
                } else {
                    Text(keptWords.joined(separator: ", ")).textSelection(.enabled)
                }
                Button("Edit in Vocabulary") { SettingsRouter.shared.tab = .vocabulary }
            }

            if let warning = engine.cleanupWarning {
                Section { Text(warning).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apiKey = prefs.apiKey ?? ""
            hardware = detectHardware()
            engine.terms { keptWords = $0.filter { $0.source == "user" }.map(\.text) }
        }
    }

    // MARK: - Cloud

    private var cloudSection: some View {
        Section("Cloud") {
            Picker("Provider", selection: $prefs.cloudProvider) {
                ForEach(Preferences.CloudProviderChoice.allCases.filter { $0 != .fnspeak || account.isSignedIn || prefs.cloudProvider == .fnspeak }) {
                    Text($0.label).tag($0)
                }
            }
            .onChange(of: prefs.cloudProvider) {
                prefs.applyProviderDefaults()
                apiKey = prefs.apiKey ?? ""
                testResult = nil
            }
            if prefs.cloudProvider == .custom {
                TextField("Endpoint", text: $prefs.customBaseURL, prompt: Text("http://localhost:11434/v1"))
                Text("Any server that speaks the OpenAI chat completions API, such as Ollama or LM Studio. The key is optional.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if prefs.cloudProvider == .fnspeak {
                FnSpeakCleanupNote()
            } else {
                SecureField("API key", text: $apiKey)
                TextField("Model for corrections", text: $prefs.cloudModel)
                TextField("Model for everything else", text: $prefs.cloudLightModel)
            }

            HStack {
                Button("Save") {
                    prefs.apiKey = apiKey
                    engine.reconfigureCleanup()
                }
                Button("Test connection", action: testConnection).disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                if let testResult {
                    Label(testResult.message, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(testResult.ok ? Color.green : Color.red)
                        .font(.callout)
                }
            }
            Text("The key is stored in your Keychain. A test sends one tiny request containing the word \"hi\".")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func testConnection() {
        testing = true
        testResult = nil
        let provider = prefs.cloudProvider
        let url = prefs.customBaseURL
        let key = apiKey
        let model = prefs.cloudLightModel.trimmingCharacters(in: .whitespaces).isEmpty ? prefs.cloudModel : prefs.cloudLightModel
        Task {
            let outcome = await CloudConnectionTest.run(provider: provider, customBaseURL: url, apiKey: key, model: model)
            testResult = outcome
            testing = false
        }
    }

    // MARK: - Helpers

    private var explanation: String {
        switch prefs.mode {
        case "local":
            return "A small language model on this Mac fixes fillers, repeats and self-corrections. Nothing leaves your Mac. It adds a moment of delay and needs a few GB of memory."
        case "cloud":
            return "The transcript text is sent to the provider below for cleanup. Your voice is never sent. Fast on any Mac, but needs a network and an API key."
        case "filterOnly":
            return "Fixed rules remove ums, stutters and repeated words. Instant and fully offline, but it doesn't rewrite or follow corrections like \"no, I meant\"."
        default:
            return "Inserts exactly what the speech engine heard, with no cleanup at all."
        }
    }

    private func recommendation(_ hardware: Hardware) -> String {
        let name: String
        switch hardware.recommendedMode {
        case .local: name = "Local model"
        case .cloud: name = "Cloud"
        case .filterOnly: name = "Filter only"
        case .raw: name = "Raw"
        }
        let chip = hardware.appleSilicon ? "Apple silicon" : "Intel"
        return String(format: "Recommended for this Mac: %@ (%.0f GB memory, %@).", name, hardware.totalMemoryGb, chip)
    }

    private func styleBinding(for category: AppCategory) -> Binding<WritingStyle> {
        Binding(
            get: { prefs.categoryStyle(category) },
            set: { prefs.setCategoryStyle($0, for: category) }
        )
    }

    private func overrideBinding(_ bundleId: String) -> Binding<WritingStyle> {
        Binding(
            get: { WritingStyle(rawValue: prefs.styleOverrides[bundleId] ?? "") ?? .prose },
            set: { prefs.styleOverrides[bundleId] = $0.rawValue }
        )
    }
}
