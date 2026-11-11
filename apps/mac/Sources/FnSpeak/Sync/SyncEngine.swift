import Combine
import Foundation

/// Keeps notes and meetings in step with the FnSpeak server, and the
/// team glossary and team snippets in the core. Runs every minute and shortly after
/// local changes, only while signed in, and only syncs notes and meetings
/// when the user turned that on.
///
/// Each run pulls what changed on the server since the last cursor, then
/// pushes what changed here. The newest `updated_at` wins; deletions travel
/// as tombstones. Nothing syncs while a meeting is recording or being
/// summarized; the finished meeting goes up on the next run.
@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()

    @Published private(set) var lastSynced: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var syncing = false
    /// The id mapping and sharing, published for the share menus.
    @Published private(set) var state: SyncState?
    /// Bumped when the team snippets in the core change, so the Snippets tab reloads.
    @Published private(set) var snippetsRevision = 0

    private weak var engine: EngineController?
    private weak var meetings: MeetingController?
    private let prefs = Preferences.shared
    private var account: AccountController { AccountController.shared }
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Timer?
    private var rerun = false
    private var appliedGlossary: [String]?
    private var appliedSnippets: [ServerClient.TeamSnippet]?
    /// Revisions this engine caused by importing, so they don't trigger another run.
    private var ownNotesRevision: Int?
    private var ownMeetingsRevision: Int?
    /// Core calls block; they run here, off the main thread.
    private let worker = DispatchQueue(label: "com.fnspeak.sync", qos: .utility)

    private static let interval: TimeInterval = 60
    private static let notesPerPush = 200

    func start(engine: EngineController, meetings: MeetingController) {
        guard timer == nil else { return }
        self.engine = engine
        self.meetings = meetings
        _ = loadState()

        NotesStore.shared.$revision
            .dropFirst()
            .debounce(for: .seconds(3), scheduler: RunLoop.main)
            .sink { [weak self] revision in
                guard let self, revision != self.ownNotesRevision else { return }
                self.requestSync()
            }
            .store(in: &subscriptions)
        meetings.$revision
            .dropFirst()
            .debounce(for: .seconds(3), scheduler: RunLoop.main)
            .sink { [weak self] revision in
                guard let self, revision != self.ownMeetingsRevision else { return }
                self.requestSync()
            }
            .store(in: &subscriptions)
        engine.$status
            .filter { $0 == .ready }
            .first()
            .sink { [weak self] _ in
                self?.requestSync()
                AccountController.shared.refresh()
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .accountChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if AccountController.shared.isSignedIn {
                    _ = self.loadState()
                    self.requestSync()
                } else {
                    self.signedOut()
                }
            }
            .store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestSync() }
        }
    }

    func requestSync() {
        guard account.isSignedIn else { return }
        if syncing {
            rerun = true
            return
        }
        Task { await sync() }
    }

    /// Forget status and drop the team's terms from the vocabulary. The id
    /// mapping stays on disk so signing in again doesn't duplicate anything.
    private func signedOut() {
        lastSynced = nil
        lastError = nil
        state = nil
        appliedGlossary = nil
        appliedSnippets = nil
        if let core = engine?.core {
            worker.async {
                _ = try? core.replaceTerms(source: .team, terms: [])
                _ = try? core.replaceTeamSnippets(snippets: [])
                DispatchQueue.main.async { self.snippetsRevision += 1 }
            }
        }
    }

    // MARK: - Sharing

    enum Kind { case note, meeting }

    /// The team an item is shared with, if any.
    func team(of kind: Kind, localId: Int64) -> String? {
        entry(kind, localId)?.value.teamId
    }

    /// Whether this user can change the item's sharing: false for items a teammate shared.
    func canShare(_ kind: Kind, localId: Int64) -> Bool {
        guard let owner = entry(kind, localId)?.value.owner else { return true }
        return owner == prefs.accountUserId
    }

    func share(_ kind: Kind, localId: Int64, with teamId: String?) {
        guard var state = loadState() else { return }
        let id = entry(kind, localId)?.key ?? UUID().uuidString.lowercased()
        var item = (kind == .note ? state.notes[id] : state.meetings[id])
            ?? SyncState.Item(localId: localId, fingerprint: "", updatedAt: 0, owner: state.userId)
        guard item.owner == state.userId else { return }
        item.teamId = teamId
        item.fingerprint = ""
        if kind == .note { state.notes[id] = item } else { state.meetings[id] = item }
        state.save()
        self.state = state
        requestSync()
    }

    private func entry(_ kind: Kind, _ localId: Int64) -> (key: String, value: SyncState.Item)? {
        guard let state else { return nil }
        return (kind == .note ? state.notes : state.meetings).first { $0.value.localId == localId }
    }

    private func loadState() -> SyncState? {
        guard let userId = prefs.accountUserId else { return nil }
        let server = prefs.serverURL
        if let state, state.server == server, state.userId == userId, state.database == SyncState.databaseStamp { return state }
        let loaded = SyncState.load(server: server, userId: userId)
        state = loaded
        return loaded
    }

    // MARK: - Running

    private func sync() async {
        guard account.isSignedIn, let client = account.client, let engine, engine.isReady, let core = engine.core else { return }
        syncing = true
        do {
            if prefs.syncGlossary {
                try await pullGlossary(client, core)
            } else if appliedGlossary != [] {
                try await onWorker { _ = try core.replaceTerms(source: .team, terms: []) }
                appliedGlossary = []
            }
            if prefs.syncTeamSnippets {
                try await pullSnippets(client, core)
            } else if appliedSnippets != [] {
                try await onWorker { _ = try core.replaceTeamSnippets(snippets: []) }
                appliedSnippets = []
                snippetsRevision += 1
            }
            if prefs.syncEnabled {
                if (meetings?.phase ?? .idle) == .idle {
                    try await syncItems(client, core)
                    lastSynced = Date()
                } else {
                    // Picked up again when the meeting finishes and bumps its revision.
                    Log.debug("Sync: waiting for the meeting to finish")
                }
            }
            lastError = nil
        } catch ServerError.signedOut {
            account.tokenRejected()
        } catch {
            lastError = error.localizedDescription
            Log.error("Sync: \(error.localizedDescription)")
        }
        syncing = false
        if rerun {
            rerun = false
            requestSync()
        }
    }

    private func pullGlossary(_ client: ServerClient, _ core: FnSpeakEngine) async throws {
        var seen = Set<String>()
        let terms = try await client.glossary().map(\.term).filter { seen.insert($0.lowercased()).inserted }.sorted()
        guard terms != appliedGlossary else { return }
        try await onWorker { _ = try core.replaceTerms(source: .team, terms: terms) }
        appliedGlossary = terms
        Log.info("Sync: \(terms.count) team glossary terms")
    }

    /// A failed pull throws before anything is replaced, so the snippets
    /// already in the core stay as they were.
    private func pullSnippets(_ client: ServerClient, _ core: FnSpeakEngine) async throws {
        let remote = try await client.teamSnippets()
        guard remote != appliedSnippets else { return }
        let input = remote.map {
            TeamSnippetInput(id: $0.id, trigger: $0.trigger, text: $0.text, teamId: $0.teamId,
                             teamName: $0.teamName, canEdit: $0.canEdit, updatedAt: $0.updatedAt)
        }
        try await onWorker { _ = try core.replaceTeamSnippets(snippets: input) }
        appliedSnippets = remote
        snippetsRevision += 1
        Log.info("Sync: \(remote.count) team snippets")
    }

    private struct Local {
        var notes: [Int64: Note]
        var meetings: [Int64: Meeting]
    }

    private func syncItems(_ client: ServerClient, _ core: FnSpeakEngine) async throws {
        guard var state = loadState() else { return }
        var local = try await onWorker {
            Local(notes: Dictionary(uniqueKeysWithValues: try core.notes(limit: UInt32.max).map { ($0.id, $0) }),
                  meetings: Dictionary(uniqueKeysWithValues: try core.meetings(limit: 100_000).map { ($0.id, $0) }))
        }
        var changedNotes = false
        var changedMeetings = false

        // Pull.
        var more = true
        while more {
            let changes = try await client.pull(since: state.cursor)
            for remote in changes.meetings {
                changedMeetings = try await apply(remote, force: false, to: &state, local: &local, core) || changedMeetings
            }
            for remote in changes.notes {
                changedNotes = try await apply(remote, force: false, to: &state, local: &local, core) || changedNotes
            }
            state.cursor = changes.cursor
            more = changes.more
            state.save()
            self.state = state
        }

        // Push meetings first, so notes can point at them.
        try await pushMeetings(client, core, &state, &local, changed: &changedMeetings)
        try await pushNotes(client, core, &state, &local, changed: &changedNotes)
        state.save()
        self.state = state

        if changedNotes { notesChanged() }
        if changedMeetings { meetingsChanged() }
    }

    // MARK: - Pulling

    /// Apply a note from the server. Returns whether anything local changed.
    private func apply(_ remote: ServerClient.RemoteNote, force: Bool, to state: inout SyncState,
                       local: inout Local, _ core: FnSpeakEngine) async throws -> Bool {
        var entry = state.notes[remote.id]
        if remote.deleted {
            guard let entry else { return false }
            state.notes[remote.id] = nil
            guard local.notes[entry.localId] != nil else { return false }
            _ = try await onWorker { try core.deleteNote(id: entry.localId) }
            local.notes[entry.localId] = nil
            NoteExporter.remove(id: entry.localId)
            return true
        }
        if let entry, !force, remote.updatedAt <= entry.updatedAt { return false }
        if let entry, !force, entry.owner == state.userId, let note = local.notes[entry.localId],
           Fingerprint.note(note) != entry.fingerprint, note.updatedAt * 1000 > remote.updatedAt {
            // Edited here since the last sync, and more recently: ours wins and goes up next.
            return false
        }
        if entry == nil {
            // The same note already here (say, after signing in again): link it instead of duplicating.
            let mapped = Set(state.notes.values.map(\.localId))
            if let twin = local.notes.values.first(where: { !mapped.contains($0.id) && $0.title == remote.title && $0.bodyMd == remote.bodyMd }) {
                entry = SyncState.Item(localId: twin.id, fingerprint: "", updatedAt: 0, owner: remote.userId)
            }
        }
        let input = NoteInput(
            title: remote.title, bodyMd: remote.bodyMd, source: Self.noteSource(remote.source),
            meetingId: remote.meetingId.flatMap { state.meetings[$0]?.localId },
            tags: (try? JSONDecoder().decode([String].self, from: Data(remote.tagsJson.utf8))) ?? [],
            pinned: remote.pinned)
        let localId = entry.flatMap { local.notes[$0.localId] != nil ? $0.localId : nil }
        let note = try await onWorker {
            try core.putSyncedNote(id: localId, note: input, createdAt: remote.createdAt / 1000, updatedAt: remote.updatedAt / 1000)
        }
        local.notes[note.id] = note
        state.notes[remote.id] = SyncState.Item(
            localId: note.id, fingerprint: Fingerprint.note(note), updatedAt: remote.updatedAt, owner: remote.userId,
            teamId: remote.visibility == "team" ? remote.sharedWithTeamId : nil)
        if let folder = NoteExporter.folder { try? NoteExporter.write(note, to: folder) }
        return true
    }

    private func apply(_ remote: ServerClient.RemoteMeeting, force: Bool, to state: inout SyncState,
                       local: inout Local, _ core: FnSpeakEngine) async throws -> Bool {
        var entry = state.meetings[remote.id]
        if remote.deleted {
            guard let entry else { return false }
            state.meetings[remote.id] = nil
            guard local.meetings[entry.localId] != nil else { return false }
            _ = try? await onWorker { try core.deleteMeeting(id: entry.localId) }
            local.meetings[entry.localId] = nil
            return true
        }
        if let entry, !force, remote.updatedAt <= entry.updatedAt { return false }
        if let entry, !force, entry.owner == state.userId, let meeting = local.meetings[entry.localId],
           fingerprint(meeting) != entry.fingerprint {
            // Changed here since the last sync; ours goes up next with a newer time.
            return false
        }
        if let entry, meetings?.current?.id == entry.localId { return false }
        if entry == nil {
            let mapped = Set(state.meetings.values.map(\.localId))
            if let twin = local.meetings.values.first(where: {
                !mapped.contains($0.id) && $0.startedAt == remote.startedAt / 1000 && $0.title == remote.title
            }) {
                entry = SyncState.Item(localId: twin.id, fingerprint: "", updatedAt: 0, owner: remote.userId)
            }
        }
        var remote = remote
        if remote.segments == nil {
            remote = try await client().meeting(id: remote.id)
        }
        let decoder = JSONDecoder()
        let items = (try? decoder.decode([ServerClient.ActionItemUpload].self, from: Data(remote.actionItemsJson.utf8))) ?? []
        let synced = SyncedMeeting(
            startedAt: remote.startedAt / 1000,
            endedAt: remote.endedAt.map { $0 / 1000 },
            title: remote.title,
            participants: (try? decoder.decode([String].self, from: Data(remote.participantsJson.utf8))) ?? [],
            status: remote.status == "done" ? .done : .processing,
            summaryMd: remote.summaryMd.isEmpty ? nil : remote.summaryMd,
            actionItems: items.map { ActionItem(owner: $0.owner, task: $0.task, due: $0.due, done: $0.done) },
            transcriptMd: (remote.rawTranscriptMd ?? "").isEmpty ? nil : remote.rawTranscriptMd,
            segments: (remote.segments ?? []).map {
                SyncedSegment(startedMs: $0.startedMs, endedMs: $0.endedMs, speaker: $0.speaker, text: $0.text)
            })
        let localId = entry.flatMap { local.meetings[$0.localId] != nil ? $0.localId : nil }
        let meeting = try await onWorker { try core.putSyncedMeeting(id: localId, meeting: synced) }
        local.meetings[meeting.id] = meeting
        state.meetings[remote.id] = SyncState.Item(
            localId: meeting.id, fingerprint: fingerprint(meeting), transcript: Fingerprint.transcript(meeting),
            updatedAt: remote.updatedAt, owner: remote.userId,
            teamId: remote.visibility == "team" ? remote.sharedWithTeamId : nil, startedAt: remote.startedAt)
        return true
    }

    // MARK: - Pushing

    private func pushNotes(_ client: ServerClient, _ core: FnSpeakEngine, _ state: inout SyncState,
                           _ local: inout Local, changed: inout Bool) async throws {
        let now = Self.nowMs
        var uploads: [(upload: ServerClient.NoteUpload, fingerprint: String)] = []
        var byLocal = Dictionary(state.notes.map { ($0.value.localId, $0.key) }, uniquingKeysWith: { a, _ in a })

        for note in local.notes.values.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            let fp = Fingerprint.note(note)
            let id = byLocal[note.id] ?? UUID().uuidString.lowercased()
            let item = state.notes[id] ?? SyncState.Item(localId: note.id, fingerprint: "", updatedAt: 0, owner: state.userId)
            guard item.owner == state.userId, fp != item.fingerprint else { continue }
            if state.notes[id] == nil { state.notes[id] = item; byLocal[note.id] = id }
            uploads.append((ServerClient.NoteUpload(
                id: id, createdAt: note.createdAt * 1000, updatedAt: max(note.updatedAt * 1000, item.updatedAt + 1),
                title: note.title, bodyMd: note.bodyMd, source: note.source.label,
                meetingId: note.meetingId.flatMap { state.meetingId(local: $0) }, tagsJson: note.tags, pinned: note.pinned,
                sharedWithTeamId: item.teamId, visibility: item.teamId == nil ? "private" : "team", deleted: false), fp))
        }
        // Deleted here: tell the server, if it ever had them.
        for (id, item) in state.notes where local.notes[item.localId] == nil {
            guard item.owner == state.userId, item.updatedAt > 0 else {
                state.notes[id] = nil
                continue
            }
            uploads.append((ServerClient.NoteUpload(
                id: id, createdAt: now, updatedAt: max(now, item.updatedAt + 1), title: "", bodyMd: "", source: "quick",
                meetingId: nil, tagsJson: [], pinned: false, sharedWithTeamId: nil, visibility: "private", deleted: true), ""))
        }

        for start in stride(from: 0, to: uploads.count, by: Self.notesPerPush) {
            let batch = Array(uploads[start..<min(start + Self.notesPerPush, uploads.count)])
            let results = try await client.push(notes: batch.map(\.upload), meetings: [])
            for result in results {
                guard let sent = batch.first(where: { $0.upload.id == result.id }) else { continue }
                if sent.upload.deleted {
                    state.notes[result.id] = nil
                    continue
                }
                switch result.status {
                case "applied":
                    state.notes[result.id]?.fingerprint = sent.fingerprint
                    state.notes[result.id]?.updatedAt = sent.upload.updatedAt
                case "stale":
                    // The server has a newer copy: take it.
                    let remote = try await client.note(id: result.id)
                    changed = try await apply(remote, force: true, to: &state, local: &local, core) || changed
                default:
                    // Don't retry until it changes again.
                    state.notes[result.id]?.fingerprint = sent.fingerprint
                    lastError = "Couldn't sync “\(sent.upload.title)”: \(result.error ?? result.status)"
                    Log.error("Sync: note \(result.id) \(result.status): \(result.error ?? "")")
                }
            }
        }
    }

    private func pushMeetings(_ client: ServerClient, _ core: FnSpeakEngine, _ state: inout SyncState,
                              _ local: inout Local, changed: inout Bool) async throws {
        let now = Self.nowMs
        let byLocal = Dictionary(state.meetings.map { ($0.value.localId, $0.key) }, uniquingKeysWith: { a, _ in a })
        let recording = meetings?.current?.id

        for summary in local.meetings.values.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard summary.status != .recording, summary.id != recording else { continue }
            let fp = fingerprint(summary)
            let id = byLocal[summary.id] ?? UUID().uuidString.lowercased()
            let item = state.meetings[id] ?? SyncState.Item(localId: summary.id, fingerprint: "", updatedAt: 0, owner: state.userId)
            guard item.owner == state.userId, fp != item.fingerprint else { continue }
            let transcript = Fingerprint.transcript(summary)
            var segments: [ServerClient.RemoteSegment]?
            if item.updatedAt == 0 || item.transcript != transcript {
                guard let full = try await onWorker({ try core.meeting(id: summary.id) }) else { continue }
                segments = full.segments.map { ServerClient.RemoteSegment(startedMs: $0.startedMs, endedMs: $0.endedMs, speaker: $0.speaker, text: $0.text) }
            }
            let upload = ServerClient.MeetingUpload(
                id: id, startedAt: summary.startedAt * 1000, endedAt: summary.endedAt.map { $0 * 1000 },
                updatedAt: max(now, item.updatedAt + 1), title: summary.title, participantsJson: summary.participants,
                status: Self.statusName(summary.status), summaryMd: summary.summaryMd ?? "",
                actionItemsJson: summary.actionItems.map {
                    ServerClient.ActionItemUpload(owner: $0.owner, task: $0.task, due: $0.due, done: $0.done)
                },
                rawTranscriptMd: summary.transcriptMd ?? "", sharedWithTeamId: item.teamId,
                visibility: item.teamId == nil ? "private" : "team", deleted: false, segments: segments)
            state.meetings[id] = item
            let result = try await client.push(notes: [], meetings: [upload]).first
            switch result?.status {
            case "applied":
                state.meetings[id]?.fingerprint = fp
                state.meetings[id]?.transcript = transcript
                state.meetings[id]?.updatedAt = upload.updatedAt
                state.meetings[id]?.startedAt = upload.startedAt
            case "stale":
                let remote = try await client.meeting(id: id)
                changed = try await apply(remote, force: true, to: &state, local: &local, core) || changed
            default:
                state.meetings[id]?.fingerprint = fp
                lastError = "Couldn't sync the meeting “\(summary.title)”: \(result?.error ?? result?.status ?? "no answer")"
                Log.error("Sync: meeting \(id) \(result?.status ?? "-"): \(result?.error ?? "")")
            }
        }

        let deleted = state.meetings.filter { local.meetings[$0.value.localId] == nil }
        var tombstones: [ServerClient.MeetingUpload] = []
        for (id, item) in deleted {
            guard item.owner == state.userId, item.updatedAt > 0, let startedAt = item.startedAt else {
                state.meetings[id] = nil
                continue
            }
            tombstones.append(ServerClient.MeetingUpload(
                id: id, startedAt: startedAt, endedAt: nil, updatedAt: max(now, item.updatedAt + 1), title: "",
                participantsJson: [], status: "done", summaryMd: "", actionItemsJson: [], rawTranscriptMd: "",
                sharedWithTeamId: nil, visibility: "private", deleted: true, segments: nil))
        }
        if !tombstones.isEmpty {
            _ = try await client.push(notes: [], meetings: tombstones)
            for t in tombstones { state.meetings[t.id] = nil }
        }
    }

    // MARK: - Helpers

    private func fingerprint(_ meeting: Meeting) -> String {
        Fingerprint.meeting(meeting)
    }

    private func client() throws -> ServerClient {
        guard let client = account.client else { throw ServerError.signedOut }
        return client
    }

    private func notesChanged() {
        NotesStore.shared.reloadAfterSync()
        ownNotesRevision = NotesStore.shared.revision
    }

    private func meetingsChanged() {
        guard let meetings else { return }
        meetings.reloadAfterSync()
        ownMeetingsRevision = meetings.revision
    }

    private func onWorker<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            worker.async { continuation.resume(with: Result { try body() }) }
        }
    }

    private static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    nonisolated static func statusName(_ status: MeetingStatus) -> String {
        switch status {
        case .recording: return "recording"
        case .processing: return "processing"
        case .done: return "done"
        }
    }

    private static func noteSource(_ name: String) -> NoteSource {
        switch name {
        case "meeting": return .meeting
        case "dictation": return .dictation
        default: return .quick
        }
    }
}
