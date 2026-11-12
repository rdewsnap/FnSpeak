import SwiftUI

/// The short list of things that make FnSpeak fully work, shown in the
/// sidebar until they're done or the user hides it.
struct SetupChecklist: View {
    @ObservedObject private var downloader = ModelDownloader.shared
    @ObservedObject private var upcoming = UpcomingMeetings.shared
    @AppStorage("setupChecklistHidden") private var hidden = false
    @State private var tick = 0
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private struct Step: Identifiable {
        let id: String
        let title: String
        let done: Bool
        let action: () -> Void
    }

    private var steps: [Step] {
        _ = tick
        _ = downloader.revision
        let router = SettingsRouter.shared
        return [
            Step(id: "mic", title: "Allow the microphone", done: Permission.microphone.state == .allowed) {
                Permission.microphone.request()
            },
            Step(id: "ax", title: "Allow Accessibility", done: Permission.accessibility.state == .allowed) {
                Permission.accessibility.request()
            },
            Step(id: "model", title: "Download the speech model",
                 done: ModelDownloader.Item.whisper.isPresent || ModelDownloader.Item.parakeet.isPresent) {
                router.tab = .home
            },
            Step(id: "calendar", title: "Connect your calendar", done: upcoming.hasCalendarAccess) {
                router.tab = .integrations
            },
            Step(id: "mcp", title: "Connect an AI assistant", done: MCPSetup.isConnected) {
                router.tab = .notes
            },
        ]
    }

    var body: some View {
        let steps = steps
        let done = steps.filter(\.done).count
        if !hidden && done < steps.count {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Finish setting up").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button { hidden = true } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                        .help("Hide this. Everything here is also in Settings.")
                }
                ProgressView(value: Double(done), total: Double(steps.count))
                    .progressViewStyle(.linear).controlSize(.small).tint(.green)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(steps) { step in
                        Button(action: step.action) {
                            HStack(spacing: 7) {
                                Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(step.done ? Color.green : Color.secondary)
                                Text(step.title)
                                    .font(.system(size: 12))
                                    .foregroundStyle(step.done ? .secondary : .primary)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(step.done)
                    }
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .onReceive(poll) { _ in tick += 1 }
        }
    }
}
