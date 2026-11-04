import AppKit
import SwiftUI

struct AdvancedTab: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController

    @State private var hardware = detectHardware()
    @State private var exportNotice: String?
    @AppStorage(ModelLocator.fastModelKey) private var fastModel = ""

    var body: some View {
        Form {
            Section("Speech engine") {
                Picker("Engine", selection: $prefs.speechEngine) {
                    Text("Whisper (uses your vocabulary while listening)").tag("whisper")
                    Text("Parakeet (faster)").tag("parakeet")
                }
                .onChange(of: prefs.speechEngine) { engine.load() }
                LabeledContent("Whisper model", value: ModelLocator.whisperModel?.lastPathComponent ?? "Not found")
                LabeledContent("Parakeet model", value: ModelLocator.parakeetModel?.lastPathComponent ?? "Not found")
                HStack {
                    Button("Show models folder") {
                        try? FileManager.default.createDirectory(at: ModelLocator.modelsDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([ModelLocator.modelsDirectory])
                    }
                    Button("Reload models") { engine.load() }
                }
                if case .failed(let message) = engine.status {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
            }

            if prefs.mode == "local" {
                Section("Fast model") {
                    Picker("Fast model for simple dictations", selection: $fastModel) {
                        Text("None").tag("")
                        ForEach(ModelLocator.fastModelCandidates, id: \.lastPathComponent) {
                            Text($0.lastPathComponent).tag($0.lastPathComponent)
                        }
                    }
                    .onChange(of: fastModel) { engine.reconfigureCleanup() }
                    Text("Dictations with no self-corrections go to this smaller model; the rest use the main one. Put extra .gguf files in the models folder. Uses more memory, since both models stay loaded.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("This Mac") {
                LabeledContent("Memory", value: String(format: "%.0f GB", hardware.totalMemoryGb))
                LabeledContent("Chip", value: hardware.appleSilicon ? "Apple silicon" : "Intel")
                if let gpu = hardware.gpuMemoryGb {
                    LabeledContent("GPU memory", value: String(format: "%.0f GB", gpu))
                }
                LabeledContent("Recommended cleanup", value: label(hardware.recommendedMode))
                HStack {
                    Button("Detect again") { hardware = detectHardware() }
                    Button("Use recommended") {
                        prefs.mode = EngineController.name(of: hardware.recommendedMode)
                        engine.reconfigureCleanup()
                    }
                    .disabled(prefs.mode == EngineController.name(of: hardware.recommendedMode))
                }
            }

            Section("Troubleshooting") {
                Picker("Log level", selection: $prefs.logLevel) {
                    Text("Errors only").tag("error")
                    Text("Normal").tag("info")
                    Text("Detailed").tag("debug")
                }
                Text("Logs record what Flowstate did and how long it took, never what you said.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Show logs") {
                        try? FileManager.default.createDirectory(at: Log.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Log.directory)
                    }
                    Button("Export diagnostics…", action: exportDiagnostics)
                }
                if let exportNotice { Text(exportNotice).font(.callout).foregroundStyle(.secondary) }
                Text("The zip has the log, your settings and a system summary. API keys and dictated text are left out.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func label(_ mode: Mode) -> String {
        switch mode {
        case .local: return "Local model"
        case .cloud: return "Cloud"
        case .filterOnly: return "Filter only"
        case .raw: return "Raw"
        }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Flowstate-diagnostics.zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let status: String
        switch engine.status {
        case .loading: status = "loading"
        case .ready: status = "ready"
        case .failed(let message): status = "failed: \(message)"
        }
        Diagnostics.export(to: url, engineStatus: status) { result in
            switch result {
            case .success: exportNotice = "Saved \(url.lastPathComponent)."
            case .failure(let error): exportNotice = error.localizedDescription
            }
        }
    }
}
