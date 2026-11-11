import SwiftUI

/// The Account tab's teams: membership, members and invites for owners and
/// admins, creating a team, accepting an invite, and the glossary switch.
struct TeamsSection: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var account = AccountController.shared

    @State private var newTeam = ""
    @State private var inviteLink = ""
    @State private var inviteEmail: [String: String] = [:]
    @State private var inviteRole: [String: String] = [:]

    var body: some View {
        Section("Teams") {
            if account.sharedTeams.isEmpty {
                Text("You're not on a team yet. Create one and invite people, or accept an invite someone sent you.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(account.sharedTeams) { team in
                DisclosureGroup {
                    teamDetail(team)
                } label: {
                    HStack {
                        Text(team.name)
                        Spacer()
                        Text(team.role.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                TextField("New team name", text: $newTeam).onSubmit(create)
                Button("Create team", action: create).disabled(newTeam.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                TextField("Invite link from an email", text: $inviteLink, prompt: Text("https://…/v1/invites/fsi_…"))
                    .onSubmit(accept)
                Button("Accept invite", action: accept).disabled(inviteLink.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Toggle("Add my teams' glossaries to Vocabulary", isOn: $prefs.syncGlossary)
                .onChange(of: prefs.syncGlossary) { SyncEngine.shared.requestSync() }
            Toggle("Use my teams' snippets", isOn: $prefs.syncTeamSnippets)
                .onChange(of: prefs.syncTeamSnippets) { SyncEngine.shared.requestSync() }
            Text("Names and jargon your teammates add are spelled the team's way in your dictations. Add one of your own terms from its menu in Vocabulary.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func teamDetail(_ team: ServerClient.Team) -> some View {
        if let detail = account.teamDetails[team.id] {
            ForEach(detail.members) { member in
                LabeledContent(member.email, value: member.role.capitalized)
            }
            ForEach(account.pendingInvites[team.id] ?? []) { invite in
                LabeledContent(invite.email, value: "Invited")
                    .foregroundStyle(.secondary)
            }
        }
        if team.canManage {
            HStack {
                TextField("Email", text: Binding(get: { inviteEmail[team.id] ?? "" }, set: { inviteEmail[team.id] = $0 }), prompt: Text("teammate@example.com"))
                Picker("", selection: Binding(get: { inviteRole[team.id] ?? "member" }, set: { inviteRole[team.id] = $0 })) {
                    Text("Member").tag("member")
                    Text("Admin").tag("admin")
                }
                .labelsHidden().fixedSize()
                Button("Invite") {
                    account.invite(email: inviteEmail[team.id] ?? "", role: inviteRole[team.id] ?? "member", to: team)
                    inviteEmail[team.id] = ""
                }
                .disabled(!(inviteEmail[team.id] ?? "").contains("@"))
            }
            Text("They get an email with a link to join. Members can read what's shared with the team and add to its glossary; admins can also invite.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Owners and admins manage who's on this team.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func create() {
        account.createTeam(name: newTeam)
        newTeam = ""
    }

    private func accept() {
        account.acceptInvite(pasted: inviteLink)
        inviteLink = ""
    }
}

/// Context-menu items for a vocabulary term: add it to a team's glossary.
struct TeamGlossaryMenuItems: View {
    let term: String
    @ObservedObject private var account = AccountController.shared

    var body: some View {
        if account.isSignedIn {
            ForEach(account.sharedTeams) { team in
                Button("Add to \(team.name)'s glossary") { account.addToGlossary(term, team: team) }
            }
        }
    }
}
