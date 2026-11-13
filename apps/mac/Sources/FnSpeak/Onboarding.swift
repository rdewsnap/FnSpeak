import AVFoundation
import SwiftUI

/// First run: permissions, the cleanup mode picked from the hardware check,
/// the model downloads if any are needed, a try-it box, then the hotkey.
struct OnboardingView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController
    let hardware: Hardware
    /// Called when the try-it step opens, with the chosen cleanup mode: the
    /// engine and hotkey have to be running for it to work.
    let prepare: (String) -> Void
    let onDone: () -> Void
    /// The step to open on; only the snapshot tool starts anywhere but the first.
    var startAt = 0

    private enum Step: Int, CaseIterable {
        case permissions, cleanup, models, tryIt, hotkey

        var title: String {
            switch self {
            case .permissions: return "Welcome to FnSpeak"
            case .cleanup: return "How should it clean up?"
            case .models: return "Get the models"
            case .tryIt: return "Try it"
            case .hotkey: return "Pick your hotkey"
            }
        }
    }

    @State private var step = Step.permissions
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var axGranted = ContextReader.requestAccessibility(prompt: false)
    @State private var choice = "filterOnly"
    /// Meetings need models that dictation doesn't, so they're only fetched
    /// for someone who says they'll record meetings.
    @State private var recordsMeetings = false
    @State private var practice = ""
    /// The models listed on the download step.
    @State private var shownModels: [ModelDownloader.Item] = []
    @ObservedObject private var downloader = ModelDownloader.shared
    @FocusState private var practiceFocused: Bool

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(step.title).font(Theme.Fonts.title)

            Group {
                switch step {
                case .permissions: permissions
                case .cleanup: cleanup
                case .models: models
                case .tryIt: tryIt
                case .hotkey: hotkey
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 540, height: 480)
        .onAppear {
            choice = EngineController.name(of: hardware.recommendedMode)
            if let start = Step(rawValue: startAt) { step = start }
        }
        .onReceive(poll) { _ in
            // Permissions are granted in System Settings, so keep checking.
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            axGranted = ContextReader.requestAccessibility(prompt: false)
        }
    }

    private var micGranted: Bool { micStatus == .authorized }

    // MARK: - Steps

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hold a key, talk, let go. FnSpeak types what you meant, spelled the way your projects and contacts spell it.")
            GroupBox("Two things macOS has to allow") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Permission.allCases) { PermissionRow($0) }
                }
                .padding(4)
            }
            Text("These update as soon as you allow them.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var cleanup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(format: "This Mac has %.0f GB of memory.", hardware.totalMemoryGb)).foregroundStyle(.secondary)
            Picker("", selection: $choice) {
                Text("Local model — everything stays on this Mac").tag("local")
                Text("Cloud — better on slower Macs; only text is sent, never audio").tag("cloud")
                Text("Filter only — instant, removes ums and stutters").tag("filterOnly")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: choice) { shownModels = [] }
            if choice == "cloud" {
                Text("Add an API key in Settings → Cleanup to turn this on. Until then FnSpeak uses Filter only.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("You can change this any time in Settings.").font(.callout).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Toggle("I'll record meetings with FnSpeak too", isOn: $recordsMeetings)
                .onChange(of: recordsMeetings) { shownModels = [] }
            Text("Adds what meetings need to the downloads: a small model that tells the people on a call apart, and one that can write summaries if this Mac doesn't have one. Leave it off and you can still get them later from a meeting.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What still has to be downloaded for the chosen setup.
    private var neededModels: [(item: ModelDownloader.Item, note: String)] {
        _ = downloader.revision
        var needed: [(ModelDownloader.Item, String)] = []
        if !ModelDownloader.Item.whisper.isPresent { needed.append((.whisper, Self.note(for: .whisper))) }
        if choice == "local", !ModelDownloader.Item.cleanup.isPresent { needed.append((.cleanup, Self.note(for: .cleanup))) }
        if recordsMeetings {
            if !ModelDownloader.Item.speakers.isPresent { needed.append((.speakers, Self.note(for: .speakers))) }
            // The cleanup download is a general model and writes summaries
            // itself. Only a Mac that already has a cleanup-only model
            // needs a second one for them.
            if choice == "local", ModelLocator.lacksSummaryModel { needed.append((.general, Self.note(for: .general))) }
        }
        return needed
    }

    private static func note(for item: ModelDownloader.Item) -> String {
        switch item {
        case .whisper: return "Turns your voice into text."
        case .cleanup: return "Tidies what you said."
        case .parakeet: return "A faster speech model."
        case .speakers: return "Tells the people on a call apart."
        case .general: return "Writes meeting summaries."
        }
    }

    private var speechModelReady: Bool {
        _ = downloader.revision
        return ModelDownloader.Item.whisper.isPresent || ModelDownloader.Item.parakeet.isPresent
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("FnSpeak runs its models on this Mac, so they're downloaded once, now. Your voice never leaves the machine.")
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(shownModels) { ModelDownloadRow(item: $0, note: Self.note(for: $0)) }
                }
                .padding(4)
            }
            if shownModels.contains(.cleanup), !ModelDownloader.Item.cleanup.isPresent {
                Text("The cleanup model can finish in the background. Until it lands, FnSpeak uses the instant filter.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            // Fixed when the step opens, so a row stays (ticked) after its download finishes.
            if shownModels.isEmpty { shownModels = neededModels.map(\.item) }
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Click the box, then \(prefs.triggerStyle == "toggle" ? "press" : "hold") **\(prefs.hotkey.displayName)** and say a sentence.")
            TextField("Your words appear here", text: $practice, axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(.roundedBorder)
                .focused($practiceFocused)
            switch engine.status {
            case .loading:
                Label("Loading the speech model…", systemImage: "hourglass").foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            case .ready:
                if !practice.isEmpty {
                    Label("That's it. This is what dictating feels like everywhere.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if !axGranted {
                    Label("The hotkey needs Accessibility. Go back and allow it.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Label("Ready when you are.", systemImage: "mic").foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            prepare(choice)
            practiceFocused = true
        }
    }

    private var hotkey: some View {
        Form {
            HotkeyChooser(prefs: prefs)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .permissions {
                Button("Back") { move(by: -1) }
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Circle().fill(s == step ? Theme.accent : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                }
            }
            Spacer()
            if step == .tryIt && practice.isEmpty {
                Button("Skip") { move(by: 1) }
            }
            if step == .hotkey {
                Button("Start dictating") {
                    prefs.mode = choice
                    prefs.onboarded = true
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { move(by: 1) }
                    .keyboardShortcut(.defaultAction)
                    .disabled((step == .permissions && !micGranted) || (step == .models && !speechModelReady))
            }
        }
    }

    private func move(by delta: Int) {
        guard var next = Step(rawValue: step.rawValue + delta) else { return }
        // Nothing to download: skip that step in either direction.
        if next == .models, shownModels.isEmpty, neededModels.isEmpty {
            guard let beyond = Step(rawValue: next.rawValue + delta) else { return }
            next = beyond
        }
        step = next
    }
}
