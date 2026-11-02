import SwiftUI

/// The Account tab's sync switch and status line.
struct SyncSettingsSection: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var sync = SyncEngine.shared

    var body: some View {
        Section("Sync") {
            Toggle("Sync notes and meetings", isOn: $prefs.syncEnabled)
                .onChange(of: prefs.syncEnabled) { if prefs.syncEnabled { sync.requestSync() } }
            Text("Keeps notes and meeting transcripts the same on every Mac signed in to this account, and makes them searchable from AI assistants connected to the server. Notes and meetings stay private unless you share one with a team.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if prefs.syncEnabled {
                HStack {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in status }
                    Spacer()
                    if sync.syncing { ProgressView().controlSize(.small) }
                    Button("Sync now") { sync.requestSync() }.disabled(sync.syncing)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let error = sync.lastError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        } else if sync.syncing {
            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        } else if let last = sync.lastSynced {
            Label("Synced \(Self.relative(last))", systemImage: "checkmark.icloud").foregroundStyle(.secondary)
        } else {
            Label("Not synced yet", systemImage: "icloud").foregroundStyle(.secondary)
        }
    }

    private static func relative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
