import CryptoKit
import Foundation

/// What sync remembers between runs: the server's cursor, and for every
/// synced note and meeting its server id, the version last exchanged and
/// who it's shared with. Only ids and hashes, never content.
///
/// The app's database uses integer ids and the server uses UUIDs chosen by
/// the client, so this is the mapping between the two. It belongs to one
/// server account and one notes database; if either changes it starts over
/// rather than mistaking a fresh database for a mass deletion.
struct SyncState: Codable, Equatable {
    struct Item: Codable, Equatable {
        var localId: Int64
        /// Hash of the local content as last synced; "" forces a push.
        var fingerprint: String
        /// Hash of a meeting's transcript as last pushed, so segments are only resent when it changes.
        var transcript: String?
        /// The server's `updated_at` (ms) for the version we have; 0 if never pushed.
        var updatedAt: Int64
        /// Server user id of the owner. Only the owner can change an item.
        var owner: String
        /// The team it's shared with; nil is private.
        var teamId: String?
        /// Meetings only, in ms: tombstones need it.
        var startedAt: Int64?
    }

    var server: String
    var userId: String
    /// Identifies the notes database the local ids belong to.
    var database: String
    var cursor: Int64 = 0
    /// Keyed by server id.
    var notes: [String: Item] = [:]
    var meetings: [String: Item] = [:]

    func noteId(local: Int64) -> String? { notes.first { $0.value.localId == local }?.key }
    func meetingId(local: Int64) -> String? { meetings.first { $0.value.localId == local }?.key }

    // MARK: - Storage

    private static var file: URL { ModelLocator.supportDirectory.appendingPathComponent("sync-state.json") }

    /// Changes when notes.db is replaced, e.g. the support folder was reset.
    static var databaseStamp: String {
        let path = ModelLocator.supportDirectory.appendingPathComponent("notes.db").path
        let created = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
        return created.map { String(Int64($0.timeIntervalSince1970)) } ?? "none"
    }

    /// The saved state if it belongs to this account and database, else a fresh one.
    static func load(server: String, userId: String) -> SyncState {
        let database = databaseStamp
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(SyncState.self, from: data),
           saved.server == server, saved.userId == userId, saved.database == database {
            return saved
        }
        return SyncState(server: server, userId: userId, database: database)
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: Self.file, options: .atomic)
        } catch {
            Log.error("Sync: couldn't save state (\(error.localizedDescription))")
        }
    }
}

enum Fingerprint {
    static func of(_ parts: [String]) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func note(_ n: Note) -> String {
        of([n.title, n.bodyMd, n.source.label, n.tags.joined(separator: "\u{1E}"), String(n.pinned), n.meetingId.map(String.init) ?? ""])
    }

    /// Everything about a meeting except its segments.
    static func meeting(_ m: Meeting) -> String {
        let items = m.actionItems.map { item in
            [item.owner ?? "", item.task, item.due ?? "", String(item.done)].joined(separator: "\u{1D}")
        }
        return of([m.title, m.participants.joined(separator: "\u{1E}"), SyncEngine.statusName(m.status),
                   m.endedAt.map(String.init) ?? "", m.summaryMd ?? "", items.joined(separator: "\u{1E}"), m.transcriptMd ?? ""])
    }

    static func transcript(_ m: Meeting) -> String {
        of([m.transcriptMd ?? ""])
    }
}
