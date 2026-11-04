import SwiftUI

/// "Private" or "Shared with <team>" for a note or meeting. Shows nothing
/// unless the user is signed in, syncing, and on a team.
struct ShareWithTeamMenu: View {
    let kind: SyncEngine.Kind
    let localId: Int64

    @ObservedObject private var account = AccountController.shared
    @ObservedObject private var sync = SyncEngine.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        if account.isSignedIn, prefs.syncEnabled, !account.sharedTeams.isEmpty {
            let current = sync.team(of: kind, localId: localId)
            let teamName = account.sharedTeams.first { $0.id == current }?.name
            let mine = sync.canShare(kind, localId: localId)
            Menu {
                choice("Private", selected: current == nil) { sync.share(kind, localId: localId, with: nil) }
                Divider()
                ForEach(account.sharedTeams) { team in
                    choice("Share with \(team.name)", selected: current == team.id) {
                        sync.share(kind, localId: localId, with: team.id)
                    }
                }
            } label: {
                Label(teamName.map { "Shared with \($0)" } ?? "Private", systemImage: current == nil ? "lock" : "person.2")
            }
            .disabled(!mine)
            .help(mine ? "Who can see this on the server" : "Shared with you by a teammate; only they can change it")
        }
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}
