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

    func addToGlossary(_ term: String, team: ServerClient.Team) {
        run { client in
            try await client.addGlossaryTerms([term], team: team.id)
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

    func updateTeamSnippet(_ snippet: Snippet, trigger: String, text: String) {
        guard let teamId = snippet.teamId else { return }
        run { client in
            _ = try await client.updateTeamSnippet(id: snippet.id, team: teamId, trigger: trigger, text: text)
            self.notice = "Updated \"\(trigger)\"."
            NotificationCenter.default.post(name: .accountChanged, object: self)
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
