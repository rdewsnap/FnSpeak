import AppKit
import SwiftUI

struct PrivacyTab: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var engine: EngineController
    @ObservedObject var account = AccountController.shared

    @State private var confirmClearHistory = false
    @State private var confirmDeleteVocabulary = false
    @State private var notice: String?

    var body: some View {
        KitForm {
            KitSection(title: "Permissions") {
                ForEach(Permission.allCases) { PermissionRow($0) }
            }

            KitSection(title: "Where your data goes") {
                if leaving.isEmpty {
                    Label("Nothing leaves this Mac with your current settings.", systemImage: "lock.fill")
                        .foregroundStyle(Theme.good)
                } else {
                    Label("Leaving this Mac: \(leaving.joined(separator: ", and ")). Everything else stays here.", systemImage: "arrow.up.right.circle.fill")
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                fact("mic.fill", "Your voice", "Never leaves", stays: true,
                     "Audio is turned into text on this Mac and thrown away. It isn't saved.")
                switch prefs.mode {
                case "cloud":
                    fact("text.bubble", "Dictation text", "Sent for cleanup", stays: false,
                         "After transcription, the text goes to \(prefs.cloudProvider.label) to be tidied: the transcript, any of your vocabulary it mentions, and some on-screen context (app name, window title and the text before your cursor). Apps you've excluded and password fields are never read.")
                case "local":
                    fact("text.bubble", "Dictation text", "Stays here", stays: true,
                         "Cleanup runs in a model on this Mac.")
                case "filterOnly":
                    fact("text.bubble", "Dictation text", "Stays here", stays: true,
                         "Fixed rules clean up the text on this Mac.")
                default:
                    fact("text.bubble", "Dictation text", "Stays here", stays: true,
                         "Nothing is cleaned up, and nothing is sent.")
                }
                if syncing {
                    fact("note.text", "Notes and meetings", "Synced to your account", stays: false,
                         "Titles, text, summaries and transcript text go to your account's server so your other Macs have them. Turn Sync off in Account to stop.")
                } else {
                    fact("note.text", "Notes and meetings", "Stay here", stays: true,
                         "Kept in a folder on this Mac. They only sync if you sign in and turn Sync on.")
                }
                fact("person.crop.circle", "Contacts, calendar and projects", "Stay here", stays: true,
                     "Names are read on this Mac and kept in a local list. One only leaves inside a cloud cleanup request, and only when you say it.")
                fact("chart.bar.xaxis", "Analytics", "None collected", stays: true,
                     "No tracking, telemetry or crash reports. The app also goes online for a model download or an update check, when you click the button for one.")
            }

            KitSection(title: "History") {
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

            KitSection(title: "Vocabulary") {
                Button("Delete all vocabulary…") { confirmDeleteVocabulary = true }
                    .confirmationDialog("Delete every term?", isPresented: $confirmDeleteVocabulary) {
                        Button("Delete all terms", role: .destructive) {
                            engine.clearVocabulary { count in notice = "Deleted \(count) terms." }
                        }
                    } message: {
                        Text("Names from projects, contacts and your calendar come back at the next re-index unless you turn those off in Context.")
                    }
            }

            KitSection(title: "Your data") {
                LabeledContent("Folder", value: ModelLocator.supportDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                Button("Open data folder") {
                    try? FileManager.default.createDirectory(at: ModelLocator.supportDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(ModelLocator.supportDirectory)
                }
                if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }

    /// Notes and meetings are going to the account's server.
    private var syncing: Bool { account.isSignedIn && prefs.syncEnabled }

    /// What is leaving this Mac right now, in a few words each.
    private var leaving: [String] {
        var out: [String] = []
        if prefs.mode == "cloud" { out.append("dictation text, for cleanup") }
        if syncing { out.append("notes and meetings, to sync them") }
        return out
    }

    /// One kind of data: what it is, where it goes in two words, then the detail.
    private func fact(_ symbol: String, _ title: String, _ status: String, stays: Bool, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).fontWeight(.medium)
                    Spacer()
                    KitTag(text: status, kind: stays ? .good : .warning)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
