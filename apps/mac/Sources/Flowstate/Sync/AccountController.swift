import AppKit
import Foundation

/// The optional Flowstate account: signing in by magic link, the user's
/// teams, invites, and the team glossary. Signed out, none of this
/// does anything and nothing is sent anywhere.
@MainActor
final class AccountController: ObservableObject {
    static let shared = AccountController()

    enum Phase: Equatable {
        case signedOut
        /// A sign-in link is on its way to this address.
        case waitingForLink(email: String)
        case signedIn
    }

    @Published private(set) var phase: Phase
    @Published var me: ServerClient.Me?
    @Published private(set) var teamDetails: [String: ServerClient.TeamDetail] = [:]
    @Published private(set) var pendingInvites: [String: [ServerClient.Invite]] = [:]
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var notice: String?

    /// Set by the app delegate at launch.
    weak var engine: EngineController?

    private let prefs = Preferences.shared

    private init() {
        phase = Keychain.read(account: Preferences.accountKeychainAccount) == nil ? .signedOut : .signedIn
    }

    var isSignedIn: Bool { phase == .signedIn }
    var email: String? { me?.user.email ?? prefs.accountEmail }
    var teams: [ServerClient.Team] { me?.teams ?? [] }
    /// Teams other than the personal one, which is just the user.
    var sharedTeams: [ServerClient.Team] { teams.filter { !$0.personal } }
    var usesCloud: Bool { ServerClient.normalize(prefs.serverURL) == ServerClient.normalize(ServerClient.cloudURL) }

    var client: ServerClient? {
        guard let url = ServerClient.normalize(prefs.serverURL) else { return nil }
        return ServerClient(baseURL: url, token: Keychain.read(account: Preferences.accountKeychainAccount))
    }

    // MARK: - Signing in

    func requestLink(email: String) {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@") else { return error = "Enter your email address." }
        run { client in
            try await client.requestSignInLink(email: email)
            self.phase = .waitingForLink(email: email)
            self.notice = "Check your email for a sign-in link from Flowstate."
        }
    }

    /// Finish signing in with what the user pasted: the link from the
    /// email, the token inside it, or an API token from the browser page.
    func completeSignIn(pasted: String) {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let apiToken = Self.token(prefixed: "fst_", in: text) {
            return run { client in
                var client = client
                client.token = apiToken
                let me = try await client.me()
                self.didSignIn(token: apiToken, tokenId: nil, me: me)
            }
        }
        guard let linkToken = Self.token(prefixed: "fsl_", in: text) else {
            return error = "Paste the whole sign-in link from the email."
        }
        run { client in
            let verified = try await client.verify(linkToken: linkToken, deviceName: Self.deviceName)
            var signedIn = client
            signedIn.token = verified.token
            let me = try await signedIn.me()
            self.didSignIn(token: verified.token, tokenId: verified.tokenId, me: me)
        }
    }

    func cancelSignIn() {
        phase = .signedOut
        notice = nil
        error = nil
    }

    private func didSignIn(token: String, tokenId: String?, me: ServerClient.Me) {
        Keychain.write(token, account: Preferences.accountKeychainAccount)
        prefs.accountEmail = me.user.email
        prefs.accountUserId = me.user.id
        prefs.accountTokenId = tokenId
        self.me = me
        phase = .signedIn
        notice = "Signed in as \(me.user.email)."
        Log.info("Signed in to \(prefs.serverURL)")
        NotificationCenter.default.post(name: .accountChanged, object: self)
    }

    func signOut() {
        let client = self.client
        let tokenId = prefs.accountTokenId
        Keychain.delete(account: Preferences.accountKeychainAccount)
        prefs.accountEmail = nil
        prefs.accountUserId = nil
        prefs.accountTokenId = nil
        me = nil
        teamDetails = [:]
        pendingInvites = [:]
        phase = .signedOut
        notice = nil
        error = nil
        // Without the token the server can't clean up; stop using it.
        if prefs.cloudProvider == .flowstate {
            prefs.cloudProvider = .groq
            prefs.applyProviderDefaults()
            engine?.reconfigureCleanup()
        }
        NotificationCenter.default.post(name: .accountChanged, object: self)
        // Revoke this Mac's token on the server; signed out locally either way.
        if let client, let tokenId {
            Task { try? await client.revokeToken(id: tokenId) }
        }
        Log.info("Signed out")
    }

    /// Point the app at another server. Signs out of the current one.
    func useServer(_ typed: String) {
        guard let url = ServerClient.normalize(typed) else { return error = ServerError.invalidURL.errorDescription }
        if isSignedIn { signOut() }
        prefs.serverURL = url.absoluteString
        phase = .signedOut
        error = nil
        notice = nil
    }

    // MARK: - Account details

    func refresh() {
        guard isSignedIn else { return }
        run(quiet: true) { client in
            self.me = try await client.me()
            for team in self.sharedTeams where team.canManage { try await self.loadTeam(team.id, client: client) }
        }
    }

    func loadTeam(_ id: String, client: ServerClient) async throws {
        let detail = try await client.team(id: id)
        teamDetails[id] = detail
        if detail.role == "owner" || detail.role == "admin" {
            pendingInvites[id] = try await client.invites(team: id)
        }
    }

    /// Called when the server says the token is no longer good.
    func tokenRejected() {
        guard isSignedIn else { return }
        Log.info("Server rejected the account token; signing out")
        signOut()
        error = ServerError.signedOut.errorDescription
    }

    // MARK: - Helpers

    func run(quiet: Bool = false, _ work: @escaping (ServerClient) async throws -> Void) {
        guard let client else { return error = ServerError.invalidURL.errorDescription }
        if !quiet { busy = true; error = nil; notice = nil }
        Task {
            do {
                try await work(client)
            } catch ServerError.signedOut where self.isSignedIn {
                self.tokenRejected()
            } catch {
                if !quiet || self.error == nil { self.error = error.localizedDescription }
                Log.error("Account: \(error.localizedDescription)")
            }
            if !quiet { self.busy = false }
        }
    }

    /// The first `prefix…` token in a pasted link or string, e.g. `fsl_…` in a sign-in link.
    static func token(prefixed prefix: String, in text: String) -> String? {
        guard let start = text.range(of: prefix) else { return nil }
        let token = text[start.lowerBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return token.count > prefix.count + 8 ? String(token) : nil
    }

    private static var deviceName: String {
        "Flowstate on \(Host.current().localizedName ?? "a Mac")"
    }
}

extension Notification.Name {
    /// Posted when the user signs in or out.
    static let accountChanged = Notification.Name("dev.flowstate.accountChanged")
}
