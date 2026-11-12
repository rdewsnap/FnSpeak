import SwiftUI

/// The Account tab's teams: who is on each one and what it shares, with the
/// controls each role is allowed, creating a team, accepting an invite, and
/// the glossary switch. This is how a team on its own server is managed.
struct TeamsSection: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var account = AccountController.shared

    @State private var newTeam = ""
    @State private var inviteLink = ""
    @State private var inviteEmail: [String: String] = [:]
    @State private var inviteRole: [String: String] = [:]
    /// Teams whose panels are open. The preview team starts open so it can be drawn.
    @State private var open: Set<String> = AccountController.previewsTeam ? [AccountController.previewTeamId] : []
    @State private var rename: [String: String] = [:]
    @State private var newTerms: [String: String] = [:]
    /// Someone about to be removed, or the signed-in person about to leave.
    @State private var leaving: Pending?

    private struct Pending: Identifiable {
        let member: ServerClient.Member
        let team: ServerClient.Team
        var id: String { team.id + member.userId }
    }

    var body: some View {
        KitSection(title: "Teams") {
            if account.sharedTeams.isEmpty {
                Text("You're not on a team yet. Create one and invite people, or accept an invite someone sent you.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(account.sharedTeams) { team in
                DisclosureGroup(isExpanded: Binding(
                    get: { open.contains(team.id) },
                    set: { if $0 { open.insert(team.id) } else { open.remove(team.id) } }
                )) {
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
            Text("Names and jargon your teammates add are spelled the team's way in your dictations. Add terms in a team's panel above, or one of your own from its menu in Vocabulary. Snippets your teammates share expand in your dictations too, and are managed in Snippets.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .confirmationDialog(
            leaving.map { $0.member.userId == account.me?.user.id ? "Leave \($0.team.name)?" : "Remove \($0.member.email) from \($0.team.name)?" } ?? "",
            isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }),
            presenting: leaving
        ) { pending in
            Button(pending.member.userId == account.me?.user.id ? "Leave" : "Remove", role: .destructive) {
                account.removeMember(pending.member, from: pending.team)
            }
        } message: { pending in
            Text(pending.member.userId == account.me?.user.id
                 ? "You'll stop getting this team's glossary and snippets. Someone on the team can invite you back."
                 : "They'll stop getting this team's glossary and snippets. You can invite them back.")
        }
    }

    @ViewBuilder private func teamDetail(_ team: ServerClient.Team) -> some View {
        let myId = account.me?.user.id
        if team.canManage {
            HStack {
                TextField("Team name", text: Binding(get: { rename[team.id] ?? team.name }, set: { rename[team.id] = $0 }))
                    .onSubmit { account.renameTeam(team, to: rename[team.id] ?? team.name) }
                Button("Rename") { account.renameTeam(team, to: rename[team.id] ?? team.name) }
                    .disabled({ let n = (rename[team.id] ?? team.name).trimmingCharacters(in: .whitespaces); return n.isEmpty || n == team.name }())
            }
        }

        if let detail = account.teamDetails[team.id] {
            ForEach(detail.members) { member in
                memberRow(member, in: team, isMe: member.userId == myId)
            }
            ForEach(account.pendingInvites[team.id] ?? []) { invite in
                HStack {
                    Text(invite.email).foregroundStyle(.secondary)
                    Spacer()
                    Text("Invited as \(invite.role)").font(.caption).foregroundStyle(.secondary)
                    Button("Withdraw") { account.revokeInvite(invite, team: team) }.buttonStyle(small)
                }
            }
        }
        if team.canManage {
            HStack {
                TextField("Email", text: Binding(get: { inviteEmail[team.id] ?? "" }, set: { inviteEmail[team.id] = $0 }), prompt: Text("teammate@example.com"))
                KitPicker("", selection: Binding(get: { inviteRole[team.id] ?? "member" }, set: { inviteRole[team.id] = $0 })) {
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

        glossary(of: team)
    }

    /// One member: who they are, their role, and what the signed-in person
    /// may do about it. The server has the final say on each of these.
    @ViewBuilder private func memberRow(_ member: ServerClient.Member, in team: ServerClient.Team, isMe: Bool) -> some View {
        HStack {
            Text(member.email)
            if isMe { Text("you").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if team.role == "owner" && !isMe {
                KitPicker("", selection: Binding(get: { member.role }, set: { account.setRole($0, of: member, in: team) })) {
                    Text("Owner").tag("owner")
                    Text("Admin").tag("admin")
                    Text("Member").tag("member")
                }
                .labelsHidden().fixedSize()
            } else {
                Text(member.role.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            if isMe {
                // The last owner can't leave; the server says so if they try.
                Button("Leave", role: .destructive) { leaving = Pending(member: member, team: team) }.buttonStyle(small)
            } else if team.role == "owner" || (team.role == "admin" && member.role == "member") {
                Button("Remove", role: .destructive) { leaving = Pending(member: member, team: team) }.buttonStyle(small)
            }
        }
    }

    /// The team's shared glossary: what's in it, who added it, and a place to
    /// add more. Admins can remove any term; anyone can remove their own.
    @ViewBuilder private func glossary(of team: ServerClient.Team) -> some View {
        let terms = account.teamGlossaries[team.id] ?? []
        Text("Glossary").font(Theme.Fonts.heading).frame(maxWidth: .infinity, alignment: .leading)
        if terms.isEmpty {
            Text("No shared terms yet.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        ForEach(terms) { term in
            HStack {
                Text(term.term)
                Spacer()
                if let by = term.addedBy { Text(by).font(.caption).foregroundStyle(.secondary) }
                if team.canManage || term.addedBy == account.me?.user.email {
                    Button("Remove") { account.removeFromGlossary(term, team: team) }.buttonStyle(small)
                }
            }
        }
        HStack {
            TextField("Add terms", text: Binding(get: { newTerms[team.id] ?? "" }, set: { newTerms[team.id] = $0 }), prompt: Text("Separate several with commas"))
                .onSubmit { addTerms(to: team) }
            Button("Add") { addTerms(to: team) }
                .disabled((newTerms[team.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var small: KitButtonStyle { KitButtonStyle(kind: .secondary, size: .small) }

    private func addTerms(to team: ServerClient.Team) {
        account.addToGlossary(typed: newTerms[team.id] ?? "", team: team)
        newTerms[team.id] = ""
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
