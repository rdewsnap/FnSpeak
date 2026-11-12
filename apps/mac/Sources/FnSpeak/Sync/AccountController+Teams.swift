import Foundation

/// Teams, invites and the shared glossary.
extension AccountController {
    func createTeam(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        run { client in
            let team = try await client.createTeam(name: name)
            self.me = try await client.me()
            try await self.loadTeam(team.id, client: client)
            self.notice = "Created \(team.name)."
        }
    }

    func invite(email: String, role: String, to team: ServerClient.Team) {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@") else { return error = "Enter their email address." }
        run { client in
            _ = try await client.invite(email: email, role: role, toTeam: team.id)
            try await self.loadTeam(team.id, client: client)
            self.notice = "Invited \(email) to \(team.name)."
        }
    }

    /// Accept an invite from the link in the email, or the token from it.
    func acceptInvite(pasted: String) {
        guard let token = Self.token(prefixed: "fsi_", in: pasted) else {
            return error = "Paste the invite link from the email."
        }
        run { client in
            let accepted = try await client.acceptInvite(token: token)
            self.me = try await client.me()
            self.notice = accepted.joined ? "You joined \(accepted.team.name)." : "You're already on \(accepted.team.name)."
            // Pull what the team shares, and its glossary.
            NotificationCenter.default.post(name: .accountChanged, object: self)
        }
    }

    func renameTeam(_ team: ServerClient.Team, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != team.name else { return }
        run { client in
            try await client.renameTeam(id: team.id, name: name)
            self.me = try await client.me()
            try await self.loadTeam(team.id, client: client)
            self.notice = "Renamed to \(name)."
        }
    }

    func setRole(_ role: String, of member: ServerClient.Member, in team: ServerClient.Team) {
        run { client in
            // Reload either way, so a refused change shows the role it still is.
            defer { Task { try? await self.loadTeam(team.id, client: client) } }
            try await client.setRole(role, of: member.userId, team: team.id)
            self.notice = "\(member.email) is now \(role == "admin" ? "an admin" : "a \(role)") of \(team.name)."
        }
    }

    func removeMember(_ member: ServerClient.Member, from team: ServerClient.Team) {
        let leaving = member.userId == me?.user.id
        run { client in
            try await client.removeMember(member.userId, team: team.id)
            self.me = try await client.me()
            if leaving {
                self.notice = "You left \(team.name)."
                // Stop using what the team shared.
                NotificationCenter.default.post(name: .accountChanged, object: self)
            } else {
                try await self.loadTeam(team.id, client: client)
                self.notice = "Removed \(member.email) from \(team.name)."
            }
        }
    }

    func revokeInvite(_ invite: ServerClient.Invite, team: ServerClient.Team) {
        run { client in
            try await client.revokeInvite(id: invite.id, team: team.id)
            try await self.loadTeam(team.id, client: client)
            self.notice = "Withdrew the invite to \(invite.email)."
        }
    }

    /// Add terms typed into a team's panel, separated by commas or new lines.
    func addToGlossary(typed: String, team: ServerClient.Team) {
        let terms = typed.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return }
        run { client in
            try await client.addGlossaryTerms(terms, team: team.id)
            try await self.loadTeam(team.id, client: client)
            self.notice = terms.count == 1 ? "Added \(terms[0]) to \(team.name)'s glossary." : "Added \(terms.count) terms to \(team.name)'s glossary."
            NotificationCenter.default.post(name: .accountChanged, object: self)
        }
    }

    func removeFromGlossary(_ term: ServerClient.GlossaryTerm, team: ServerClient.Team) {
        run { client in
            try await client.removeGlossaryTerm(id: term.id, team: team.id)
            try await self.loadTeam(team.id, client: client)
            self.notice = "Removed \(term.term) from \(team.name)'s glossary."
            NotificationCenter.default.post(name: .accountChanged, object: self)
        }
    }

    func addToGlossary(_ term: String, team: ServerClient.Team) {
        run { client in
            try await client.addGlossaryTerms([term], team: team.id)
            try? await self.loadTeam(team.id, client: client)
            self.notice = "Added \(term) to \(team.name)'s glossary."
            NotificationCenter.default.post(name: .accountChanged, object: self)
        }
    }

    /// Post a personal snippet to a team. The personal copy stays.
    func shareSnippet(_ snippet: Snippet, with team: ServerClient.Team) {
        run { client in
            _ = try await client.addTeamSnippet(trigger: snippet.trigger, text: snippet.text, team: team.id)
            self.notice = "Shared \"\(snippet.trigger)\" with \(team.name)."
            NotificationCenter.default.post(name: .accountChanged, object: self)
        }
    }

    /// Edit a team snippet. `completion` runs once the server has answered:
    /// nil when it accepted the edit, otherwise the message to show. A failure
    /// still goes through `run`, so a rejected token signs out as usual.
    func updateTeamSnippet(_ snippet: Snippet, trigger: String, text: String, completion: @escaping (String?) -> Void = { _ in }) {
        guard let teamId = snippet.teamId else { return completion("This snippet isn't on a team.") }
        guard client != nil else {
            run { _ in }
            return completion(error)
        }
        run { client in
            do {
                _ = try await client.updateTeamSnippet(id: snippet.id, team: teamId, trigger: trigger, text: text)
            } catch {
                completion(error.localizedDescription)
                throw error
            }
            self.notice = "Updated \"\(trigger)\"."
            NotificationCenter.default.post(name: .accountChanged, object: self)
            completion(nil)
        }
    }

    func removeTeamSnippet(_ snippet: Snippet) {
        guard let teamId = snippet.teamId else { return }
        run { client in
            try await client.removeTeamSnippet(id: snippet.id, team: teamId)
            self.notice = "Removed \"\(snippet.trigger)\" from \(snippet.teamName ?? "the team")."
            NotificationCenter.default.post(name: .accountChanged, object: self)
        }
    }
}
