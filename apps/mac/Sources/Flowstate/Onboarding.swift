import AVFoundation
import SwiftUI

/// First run: permissions, the cleanup mode picked from the hardware check, a
/// try-it box, then the hotkey.
struct OnboardingView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController
    let hardware: Hardware
    /// Called when the try-it step opens, with the chosen cleanup mode: the
    /// engine and hotkey have to be running for it to work.
    let prepare: (String) -> Void
    let onDone: () -> Void

    private enum Step: Int, CaseIterable {
        case permissions, cleanup, tryIt, hotkey

        var title: String {
            switch self {
            case .permissions: return "Welcome to Flowstate"
            case .cleanup: return "How should it clean up?"
            case .tryIt: return "Try it"
            case .hotkey: return "Pick your hotkey"
            }
        }
    }

    @State private var step = Step.permissions
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var axGranted = ContextReader.requestAccessibility(prompt: false)
    @State private var choice = "filterOnly"
    @State private var practice = ""
    @FocusState private var practiceFocused: Bool

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(step.title).font(.title2.bold())

            Group {
                switch step {
                case .permissions: permissions
                case .cleanup: cleanup
                case .tryIt: tryIt
                case .hotkey: hotkey
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 520, height: 440)
        .onAppear { choice = EngineController.name(of: hardware.recommendedMode) }
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
            Text("Hold a key, talk, let go. Flowstate types what you meant, spelled the way your projects and contacts spell it.")
            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 10) {
                    permissionRow("Microphone — to hear you", granted: micGranted,
                                  denied: micStatus == .denied || micStatus == .restricted, pane: "Privacy_Microphone") {
                        AudioRecorder.requestPermission { _ in micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
                    }
                    permissionRow("Accessibility — for the hotkey and typing into apps", granted: axGranted,
                                  denied: false, pane: "Privacy_Accessibility") {
                        _ = ContextReader.requestAccessibility(prompt: true)
                    }
                }
                .padding(4)
            }
            Text("These update here as soon as you allow them.").font(.callout).foregroundStyle(.secondary)
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
            if choice == "cloud" {
                Text("Add an API key in Settings → Cleanup to turn this on. Until then Flowstate uses Filter only.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("You can change this any time in Settings.").font(.callout).foregroundStyle(.secondary)
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
                    Circle().fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
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
                    .disabled(step == .permissions && !micGranted)
            }
        }
    }

    private func move(by delta: Int) {
        if let next = Step(rawValue: step.rawValue + delta) { step = next }
    }

    private func permissionRow(_ title: String, granted: Bool, denied: Bool, pane: String, request: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? .green : .secondary)
            Text(title)
            Spacer()
            if !granted {
                if denied {
                    Button("Open Settings") { openPane(pane) }
                } else {
                    Button("Allow", action: request)
                }
            }
        }
    }

    private func openPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
