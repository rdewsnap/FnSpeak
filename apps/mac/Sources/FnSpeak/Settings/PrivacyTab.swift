import AppKit
import SwiftUI

struct PrivacyTab: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController

    @State private var confirmClearHistory = false
    @State private var confirmDeleteVocabulary = false
    @State private var notice: String?

    var body: some View {
        Form {
            Section("What leaves this Mac") {
                fact("mic.fill", "Your voice", "Never. Audio is turned into text on this Mac and thrown away. It isn't saved.")
                switch prefs.mode {
                case "cloud":
                    fact("cloud", "Cloud cleanup is on", "After transcription, the text is sent to \(prefs.cloudProvider.label) to be tidied: the transcript, any of your vocabulary it mentions, and some on-screen context (app name, window title and the text before your cursor). Apps you've excluded and password fields are never read.")
                case "local":
                    fact("lock.fill", "Local cleanup is on", "Cleanup runs in a model on this Mac. Nothing is sent anywhere.")
                case "filterOnly":
                    fact("lock.fill", "Filter only is on", "Fixed rules clean up the text on this Mac. Nothing is sent anywhere.")
                default:
                    fact("lock.fill", "Raw is on", "Nothing is cleaned up and nothing is sent anywhere.")
                }
                fact("person.crop.circle", "Contacts, calendar and projects", "Names are read on this Mac and kept in a local list. They only leave with a cloud request, and only when you say them.")
                fact("chart.bar.xaxis", "Analytics", "None. No tracking, telemetry or crash reports. The only network requests are cloud cleanup, if you turn it on, the connection test button, sync if you sign in, and a model download or update check when you click the button for one.")
            }

            Section("History") {
                Stepper("Keep dictation history for \(prefs.historyDays) days", value: $prefs.historyDays, in: 1...365)
                    .onChange(of: prefs.historyDays) { engine.purgeHistory(olderThanDays: prefs.historyDays) { _ in } }
                Text("History is the text only, stored on this Mac, and older entries are deleted automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Clear history…") { confirmClearHistory = true }
                    .confirmationDialog("Delete all dictation history?", isPresented: $confirmClearHistory) {
                        Button("Delete history", role: .destructive) {
                            RecentDictations.shared.clear()
                            engine.purgeHistory(olderThanDays: 0) { count in
                                notice = count.map { "Deleted \($0) dictations." } ?? "Couldn't clear history."
                            }
                        }
                    } message: {
                        Text("This can't be undone.")
                    }
            }

            Section("Vocabulary") {
                Button("Delete all vocabulary…") { confirmDeleteVocabulary = true }
                    .confirmationDialog("Delete every term?", isPresented: $confirmDeleteVocabulary) {
                        Button("Delete all terms", role: .destructive) {
                            engine.clearVocabulary { count in notice = "Deleted \(count) terms." }
                        }
                    } message: {
                        Text("Names from projects, contacts and your calendar come back at the next re-index unless you turn those off in Context.")
                    }
            }

            Section("Your data") {
                LabeledContent("Folder", value: ModelLocator.supportDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                Button("Open data folder") {
                    try? FileManager.default.createDirectory(at: ModelLocator.supportDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(ModelLocator.supportDirectory)
                }
                if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private func fact(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
