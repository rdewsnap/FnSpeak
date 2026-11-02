import SwiftUI

struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController
    let indexer: PersonalIndexer

    @State private var apiKey = ""
    @State private var terms: [Term] = []
    @State private var newTerm = ""

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            cleanup.tabItem { Label("Cleanup", systemImage: "wand.and.stars") }
            vocabulary.tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
        }
        .frame(width: 520, height: 440)
        .onAppear { apiKey = prefs.apiKey ?? "" }
    }

    private var general: some View {
        Form {
            Picker("Speech engine", selection: $prefs.speechEngine) {
                Text("Whisper (uses your vocabulary while listening)").tag("whisper")
                Text("Parakeet (faster)").tag("parakeet")
            }
            .onChange(of: prefs.speechEngine) { engine.load() }

            Section("Hotkeys") {
                Text("Hold **Fn** to talk. Double-tap **Fn** for hands-free, then press Fn to finish.")
                Text("**⌃⌥Z** swaps the last dictation for exactly what you said.")
                Text("If Fn opens the emoji picker, set System Settings → Keyboard → \"Press 🌐 key to\" → Do Nothing.")
                    .foregroundStyle(.secondary)
            }

            Section("History") {
                Stepper("Keep dictation history for \(prefs.historyDays) days", value: $prefs.historyDays, in: 1...365)
                Text("Audio is never saved. Text history stays on this Mac.").foregroundStyle(.secondary)
            }

            if case .failed(let message) = engine.status {
                Section("Problem") { Text(message).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }

    private var cleanup: some View {
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
    }

    private var vocabulary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Add a name or term", text: $newTerm).onSubmit(addTerm)
                Button("Add", action: addTerm).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach(terms, id: \.text) { term in
                    HStack {
                        Text(term.text)
                        Spacer()
                        if term.source == "learned" {
                            Text("learned")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                .foregroundStyle(Color.accentColor)
                                .help("Picked up from a word you fixed after dictating")
                        } else {
                            Text(term.source).foregroundStyle(.secondary).font(.caption)
                        }
                        Button {
                            engine.removeTerm(term.text)
                            terms.removeAll { $0.text == term.text }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                TextField("Projects folder", text: $prefs.projectsFolder)
                Toggle("Contacts", isOn: $prefs.indexContacts)
                Toggle("Calendar", isOn: $prefs.indexCalendar)
                Button("Re-index") {
                    indexer.indexAll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { reloadTerms() }
                }
            }
            Toggle("Learn from my corrections", isOn: $prefs.learnFromCorrections)
                .help("When you fix a dictated word, Flowstate reads back just that text, on this Mac, and remembers the spelling.")
        }
        .padding()
        .onAppear(perform: reloadTerms)
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        engine.addTerms([term], source: .user, replacing: false)
        newTerm = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { reloadTerms() }
    }

    private func reloadTerms() {
        engine.terms { terms = $0 }
    }
}

/// First run: permissions, then the cleanup mode picked from the hardware check.
struct OnboardingView: View {
    @ObservedObject var prefs = Preferences.shared
    let hardware: Hardware
    let onDone: () -> Void

    @State private var micGranted = AudioRecorder.hasPermission
    @State private var axGranted = ContextReader.requestAccessibility(prompt: false)
    @State private var choice = "filterOnly"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Flowstate").font(.title2.bold())
            Text("Hold Fn, talk, let go. Flowstate types what you meant, spelled the way your projects and contacts spell it.")

            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 8) {
                    permissionRow("Microphone — to hear you", granted: micGranted) {
                        AudioRecorder.requestPermission { micGranted = $0 }
                    }
                    permissionRow("Accessibility — for the Fn key and typing into apps", granted: axGranted) {
                        _ = ContextReader.requestAccessibility(prompt: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { axGranted = ContextReader.requestAccessibility(prompt: false) }
                    }
                }
                .padding(4)
            }

            GroupBox("Cleanup") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: "This Mac has %.0f GB of memory.", hardware.totalMemoryGb)).foregroundStyle(.secondary)
                    Picker("", selection: $choice) {
                        Text("Local model — everything stays on this Mac").tag("local")
                        Text("Cloud — better on slower Macs; only text is sent, never audio").tag("cloud")
                        Text("Filter only — instant, removes ums and stutters").tag("filterOnly")
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if choice == "cloud" {
                        Text("Add an API key in Settings → Cleanup to turn this on. Until then Flowstate uses Filter only.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Start dictating") {
                    prefs.mode = choice
                    prefs.onboarded = true
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!micGranted)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { choice = EngineController.name(of: hardware.recommendedMode) }
    }

    private func permissionRow(_ title: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? .green : .secondary)
            Text(title)
            Spacer()
            if !granted { Button("Allow", action: request) }
        }
    }
}
