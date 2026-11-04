import Foundation

/// Talks to a FnSpeak server: FnSpeak Cloud, or anyone's self-hosted
/// copy of `crates/fnspeak-server`. Every call is optional; the app works
/// the same without an account.
struct ServerClient {
    /// The hosted service. Self-hosters type their own URL in Settings.
    static let cloudURL = "https://cloud.fnspeak.com"

    let baseURL: URL
    var token: String?

    init(baseURL: URL, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
    }

    /// A server address as typed: trims spaces and trailing slashes, adds
    /// https:// when no scheme is given. Nil when it isn't a usable URL.
    static func normalize(_ typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/v1") { text.removeLast(3) }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    // MARK: - Sign-in

    func requestSignInLink(email: String) async throws {
        let _: Status = try await send("POST", "auth/magic-link", body: ["email": email], authorized: false)
    }

    /// Swap the token from a sign-in link for an API token named after this Mac.
    func verify(linkToken: String, deviceName: String) async throws -> Verified {
        try await send("POST", "auth/verify", body: ["token": linkToken, "name": deviceName], authorized: false)
    }

    func me() async throws -> Me {
        try await send("GET", "me")
    }

    func revokeToken(id: String) async throws {
        try await sendEmpty("DELETE", "tokens/\(id)")
    }

    // MARK: - Teams

    func teams() async throws -> [Team] {
        let list: TeamList = try await send("GET", "teams")
        return list.teams
    }

    func createTeam(name: String) async throws -> Team {
        try await send("POST", "teams", body: ["name": name])
    }

    func team(id: String) async throws -> TeamDetail {
        try await send("GET", "teams/\(id)")
    }

    func invite(email: String, role: String, toTeam teamId: String) async throws -> Invite {
        try await send("POST", "teams/\(teamId)/invites", body: ["email": email, "role": role])
    }

    func invites(team teamId: String) async throws -> [Invite] {
        let list: InviteList = try await send("GET", "teams/\(teamId)/invites")
        return list.invites
    }

    func invite(token: String) async throws -> InviteInfo {
        try await send("GET", "invites/\(token)", authorized: false)
    }

    func acceptInvite(token: String) async throws -> AcceptedInvite {
        try await send("POST", "invites/\(token)/accept", body: [String: String]())
    }

    // MARK: - Glossary

    /// Terms from every team the user is on.
    func glossary() async throws -> [GlossaryTerm] {
        let list: GlossaryList = try await send("GET", "glossary")
        return list.terms
    }

    func addGlossaryTerms(_ terms: [String], team teamId: String) async throws {
        let _: AddedTerms = try await send("POST", "teams/\(teamId)/glossary", body: ["terms": terms])
    }

    // MARK: - Sync

    func pull(since cursor: Int64, limit: Int = 200) async throws -> Changes {
        try await send("GET", "sync", query: ["since": String(cursor), "limit": String(limit)])
    }

    func push(notes: [NoteUpload], meetings: [MeetingUpload]) async throws -> [PushResult] {
        let response: PushResponse = try await send("POST", "sync", body: PushBatch(notes: notes, meetings: meetings))
        return response.results
    }

    func note(id: String) async throws -> RemoteNote {
        try await send("GET", "notes/\(id)")
    }

    func meeting(id: String) async throws -> RemoteMeeting {
        try await send("GET", "meetings/\(id)", query: ["include_transcript": "true"])
    }

    // MARK: - Plumbing

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private func request(_ method: String, _ path: String, query: [String: String], authorized: Bool) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/" + path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components?.url else { throw ServerError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("FnSpeak/\(AppInfo.version) (Mac)", forHTTPHeaderField: "User-Agent")
        if authorized {
            guard let token, !token.isEmpty else { throw ServerError.signedOut }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:],
                                    body: (any Encodable)? = nil, authorized: Bool = true) async throws -> T {
        let data = try await perform(method, path, query: query, body: body, authorized: authorized)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            Log.error("Server: unexpected answer to \(method) /v1/\(path): \(error)")
            throw ServerError.unexpectedResponse
        }
    }

    private func sendEmpty(_ method: String, _ path: String) async throws {
        _ = try await perform(method, path, query: [:], body: nil, authorized: true)
    }

    private func perform(_ method: String, _ path: String, query: [String: String],
                         body: (any Encodable)?, authorized: Bool) async throws -> Data {
        var request = try request(method, path, query: query, authorized: authorized)
        if let body {
            request.httpBody = try Self.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError {
            throw ServerError.network(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ServerError.from(status: status, data: data) }
        return data
    }
}

// MARK: - Errors

enum ServerError: LocalizedError, Equatable {
    case signedOut
    case rateLimited
    case network(URLError)
    case invalidURL
    case unexpectedResponse
    /// Anything else the server said no to, with its message.
    case rejected(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .signedOut:
            return "Signed out. Sign in again in Settings → Account."
        case .rateLimited:
            return "Too many requests. Try again in a few minutes."
        case .network(let error):
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return "You appear to be offline."
            case .timedOut: return "The server didn't answer in time."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Couldn't reach \(error.failingURL?.host ?? "the server")."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                return "Couldn't make a secure connection to the server."
            default: return "Network error: \(error.localizedDescription)"
            }
        case .invalidURL:
            return "That server address isn't a valid URL."
        case .unexpectedResponse:
            return "The server sent something FnSpeak didn't understand. Is this a FnSpeak server?"
        case .rejected(_, let message):
            return message.prefix(1).uppercased() + message.dropFirst()
        }
    }

    static func from(status: Int, data: Data) -> ServerError {
        struct Envelope: Decodable {
            struct Body: Decodable {
                let code: String?
                let message: String?
            }
            let error: Body
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let body = (try? decoder.decode(Envelope.self, from: data))?.error
        switch status {
        case 401: return .signedOut
        case 429: return .rateLimited
        default:
            return .rejected(status: status, message: body?.message ?? "The server answered with HTTP \(status).")
        }
    }
}

// MARK: - Shapes

extension ServerClient {
    struct Status: Decodable { let status: String }

    struct User: Codable, Equatable {
        let id: String
        let email: String
    }

    struct Verified: Decodable {
        let token: String
        let tokenId: String
        let user: User
    }

    struct Team: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let personal: Bool
        let role: String

        var canManage: Bool { role == "owner" || role == "admin" }
    }

    struct TeamList: Decodable { let teams: [Team] }

    struct Member: Decodable, Identifiable, Equatable {
        let userId: String
        let email: String
        let role: String
        var id: String { userId }
    }

    struct TeamDetail: Decodable, Equatable {
        let id: String
        let name: String
        let personal: Bool
        let role: String
        let members: [Member]
    }

    struct Invite: Decodable, Identifiable, Equatable {
        let id: String
        let email: String
        let role: String
        let expiresAt: Int64
    }

    struct InviteList: Decodable { let invites: [Invite] }

    struct TeamRef: Decodable, Equatable {
        let id: String
        let name: String
    }

    struct InviteInfo: Decodable {
        let team: TeamRef
        let email: String
        let role: String
        let status: String
    }

    struct AcceptedInvite: Decodable {
        let team: TeamRef
        let role: String
        let joined: Bool
    }

    struct Me: Decodable, Equatable {
        struct Account: Decodable, Equatable {
            let id: String
            let email: String
        }
        let user: Account
        let teams: [Team]
    }

    struct GlossaryTerm: Decodable {
        let id: String
        let teamId: String
        let term: String
    }

    struct GlossaryList: Decodable { let terms: [GlossaryTerm] }
    struct AddedTerms: Decodable {}

    // Sync

    struct RemoteNote: Decodable {
        let id: String
        let userId: String
        let sharedWithTeamId: String?
        let visibility: String
        let createdAt: Int64
        let updatedAt: Int64
        let title: String
        let bodyMd: String
        let source: String
        let meetingId: String?
        let tagsJson: String
        let pinned: Bool
        let deleted: Bool
    }

    struct RemoteSegment: Codable {
        let startedMs: Int64
        let endedMs: Int64
        let speaker: String
        let text: String
    }

    struct RemoteMeeting: Decodable {
        let id: String
        let userId: String
        let sharedWithTeamId: String?
        let visibility: String
        let startedAt: Int64
        let endedAt: Int64?
        let updatedAt: Int64
        let title: String
        let participantsJson: String
        let status: String
        let summaryMd: String
        let actionItemsJson: String
        let deleted: Bool
        let rawTranscriptMd: String?
        let segments: [RemoteSegment]?
    }

    struct Changes: Decodable {
        let notes: [RemoteNote]
        let meetings: [RemoteMeeting]
        let cursor: Int64
        let more: Bool
    }

    struct NoteUpload: Encodable {
        let id: String
        let createdAt: Int64
        let updatedAt: Int64
        let title: String
        let bodyMd: String
        let source: String
        let meetingId: String?
        let tagsJson: [String]
        let pinned: Bool
        let sharedWithTeamId: String?
        let visibility: String
        let deleted: Bool
    }

    struct ActionItemUpload: Codable {
        let owner: String?
        let task: String
        let due: String?
        let done: Bool
    }

    struct MeetingUpload: Encodable {
        let id: String
        let startedAt: Int64
        let endedAt: Int64?
        let updatedAt: Int64
        let title: String
        let participantsJson: [String]
        let status: String
        let summaryMd: String
        let actionItemsJson: [ActionItemUpload]
        let rawTranscriptMd: String
        let sharedWithTeamId: String?
        let visibility: String
        let deleted: Bool
        /// Only sent when the transcript changed; the server keeps what it has otherwise.
        let segments: [RemoteSegment]?
    }

    struct PushBatch: Encodable {
        let notes: [NoteUpload]
        let meetings: [MeetingUpload]
    }

    struct PushResult: Decodable {
        let kind: String
        let id: String
        /// `applied`, `stale`, `forbidden` or `rejected`.
        let status: String
        let error: String?
    }

    struct PushResponse: Decodable { let results: [PushResult] }
}
