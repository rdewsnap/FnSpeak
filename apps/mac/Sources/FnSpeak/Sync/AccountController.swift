import AppKit
import CryptoKit
import Foundation

/// The optional FnSpeak account: signing in by magic link, the user's
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
    /// Nil when signed out, or when the server has no plans to show.
    @Published private(set) var plan: ServerClient.Plan?
    @Published private(set) var teamDetails: [String: ServerClient.TeamDetail] = [:]
    @Published private(set) var pendingInvites: [String: [ServerClient.Invite]] = [:]
    /// Each team's shared glossary, for the team's panel.
    @Published private(set) var teamGlossaries: [String: [ServerClient.GlossaryTerm]] = [:]
    /// The server can sign people in with Google.
    @Published private(set) var offersGoogle = false
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var notice: String?

    /// Set by the app delegate at launch.
    weak var engine: EngineController?

    private let prefs = Preferences.shared

    private init() {
        phase = Keychain.read(account: Preferences.accountKeychainAccount) == nil ? .signedOut : .signedIn
        if ProcessInfo.processInfo.environment["FNSPEAK_PREVIEW_SIGNIN"] != nil {
            // Dev hook: draw the account page signed out, with Google on offer.
            phase = .signedOut
            offersGoogle = true
        } else if Self.previewsPlan {
            phase = .signedIn
            plan = ServerClient.Plan(
                summary: "Example plan",
                detail: "128 of 1,000 used this month. Resets December 1.",
                progress: 0.128,
                actions: [.init(id: "change", title: "Change plan")]
            )
            if Self.previewsTeam { previewTeam() }
        }
    }

    /// Dev hook: a made-up team the signed-in person owns, with members, a
    /// pending invite and a few shared terms.
    static let previewsTeam = ProcessInfo.processInfo.environment["FNSPEAK_PREVIEW_PLAN"] == "team"
    static let previewTeamId = "preview-team"

    private func previewTeam() {
        let id = Self.previewTeamId
        me = ServerClient.Me(
            user: .init(id: "u1", email: "sam@example.com"),
            teams: [ServerClient.Team(id: id, name: "Acme Studio", personal: false, role: "owner")]
        )
        teamDetails[id] = ServerClient.TeamDetail(id: id, name: "Acme Studio", personal: false, role: "owner", members: [
            .init(userId: "u1", email: "sam@example.com", role: "owner"),
            .init(userId: "u2", email: "priya@example.com", role: "admin"),
            .init(userId: "u3", email: "lee@example.com", role: "member"),
        ])
        pendingInvites[id] = [ServerClient.Invite(id: "i1", email: "jo@example.com", role: "member", expiresAt: 0)]
        teamGlossaries[id] = [
            .init(id: "g1", teamId: id, term: "Kubernetes", addedBy: "sam@example.com"),
            .init(id: "g2", teamId: id, term: "Priya Raghunathan", addedBy: "priya@example.com"),
            .init(id: "g3", teamId: id, term: "pgvector", addedBy: "lee@example.com"),
        ]
    }

    /// Dev hook: draw the account page signed in, on a made-up plan.
    private static let previewsPlan = ProcessInfo.processInfo.environment["FNSPEAK_PREVIEW_PLAN"] != nil

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
            self.notice = "Check your email for a sign-in link from FnSpeak."
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

    // MARK: - Google

    /// This Mac's half of a Google sign-in in progress. It never leaves the
    /// app except to collect the finished sign-in from the server.
    private var googleVerifier: String?

    /// Ask the server whether it offers Google sign-in.
    func checkSignInProviders() {
        guard ProcessInfo.processInfo.environment["FNSPEAK_PREVIEW_SIGNIN"] == nil else { return }
        guard !isSignedIn, let client else { return offersGoogle = false }
        Task {
            let providers = try? await client.signInProviders()
            self.offersGoogle = providers?.google ?? false
        }
    }

    /// Open the browser to sign in with Google. The browser is given only a
    /// hash of a secret made up here, so nothing it sees can sign anyone in.
    func signInWithGoogle() {
        guard let base = ServerClient.normalize(prefs.serverURL) else { return error = ServerError.invalidURL.errorDescription }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return error = "Couldn't start Google sign-in. Try the emailed link instead."
        }
        let verifier = "fsg_" + bytes.map { String(format: "%02x", $0) }.joined()
        let challenge = SHA256.hash(data: Data(verifier.utf8)).map { String(format: "%02x", $0) }.joined()
        var components = URLComponents(url: base.appendingPathComponent("v1/auth/google"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "challenge", value: challenge)]
        guard let url = components?.url else { return error = ServerError.invalidURL.errorDescription }
        googleVerifier = verifier
        error = nil
        notice = "Finish signing in with Google in your browser, then come back here."
        NSWorkspace.shared.open(url)
    }

    /// Collect a Google sign-in if the browser has finished it. Called when
    /// the browser hands back to the app and when the app comes forward.
    func finishGoogleSignIn() {
        guard let verifier = googleVerifier, !isSignedIn, let client else { return }
        Task {
            do {
                let verified = try await client.verify(linkToken: verifier, deviceName: Self.deviceName)
                var signedIn = client
                signedIn.token = verified.token
                let me = try await signedIn.me()
                self.googleVerifier = nil
                self.didSignIn(token: verified.token, tokenId: verified.tokenId, me: me)
            } catch ServerError.rejected {
                // Not finished in the browser yet. Try again next time.
            } catch {
                Log.error("Google sign-in: \(error.localizedDescription)")
            }
        }
    }

    func cancelSignIn() {
        googleVerifier = nil
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
        refresh()
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
        plan = nil
        teamDetails = [:]
        pendingInvites = [:]
        teamGlossaries = [:]
        phase = .signedOut
        notice = nil
        error = nil
        // Without the token the server can't clean up; stop using it.
        if prefs.cloudProvider == .fnspeak {
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
        googleVerifier = nil
        checkSignInProviders()
    }

    // MARK: - Account details

    func refresh() {
        guard isSignedIn, !Self.previewsPlan else { return }
        run(quiet: true) { client in
            self.me = try await client.me()
            self.plan = try? await client.plan()
            // Every member can see who is on a team and what it shares.
            for team in self.sharedTeams { try await self.loadTeam(team.id, client: client) }
        }
    }

    /// Open the page for something the server offers on the plan, such as
    /// changing it. It always opens in the browser.
    func open(_ action: ServerClient.Plan.Action) {
        run { client in
            let url = try await client.planLink(for: action)
            // A web page and nothing else: never a file or another app's URL scheme.
            let local = url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? "")
            guard url.scheme == "https" || local else { throw ServerError.unexpectedResponse }
            NSWorkspace.shared.open(url)
            self.notice = "Finish in your browser. This page updates when you come back."
        }
    }

    func loadTeam(_ id: String, client: ServerClient) async throws {
        let detail = try await client.team(id: id)
        teamDetails[id] = detail
        if detail.role == "owner" || detail.role == "admin" {
            pendingInvites[id] = try await client.invites(team: id)
        }
        teamGlossaries[id] = try await client.glossary(team: id)
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
        "FnSpeak on \(Host.current().localizedName ?? "a Mac")"
    }
}

extension Notification.Name {
    /// Posted when the user signs in or out.
    static let accountChanged = Notification.Name("com.fnspeak.accountChanged")
}
