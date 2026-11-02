import SwiftUI

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
