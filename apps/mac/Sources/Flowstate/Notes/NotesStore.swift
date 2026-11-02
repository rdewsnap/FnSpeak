import Foundation

/// The app's side of notes: calls into the Rust notes store on its own queue
/// (auto-titling can run the cleanup model for a few seconds, and dictation
/// shouldn't wait behind it), mirrors notes to the export folder, and bumps
/// `revision` so open views reload.
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    /// Changes whenever a note is created, edited or deleted.
    @Published private(set) var revision = 0

    /// Set by the app delegate once at launch.
    weak var engine: EngineController?

    private let queue = DispatchQueue(label: "dev.flowstate.notes", qos: .userInitiated)
    private let prefs = Preferences.shared

    enum NotesError: LocalizedError {
        case notReady
        var errorDescription: String? { "Flowstate is still starting up" }
    }

    var isReady: Bool { engine?.core != nil }

    // MARK: - Writing

    /// Save typed or dictated text as a new note.
    func create(text: String, source: NoteSource, completion: ((Result<Note, Error>) -> Void)? = nil) {
        let input = NoteText.input(from: text, source: source, autoTitle: prefs.notesAutoTitle)
        create(input, completion: completion)
    }

    func create(_ input: NoteInput, completion: ((Result<Note, Error>) -> Void)? = nil) {
        run({ try $0.createNote(note: input) }) { [weak self] result in
            if case .success(let note) = result { self?.didChange(note) }
            completion?(result)
        }
    }

    func update(id: Int64, _ input: NoteInput, completion: ((Result<Note, Error>) -> Void)? = nil) {
        run({ try $0.updateNote(id: id, note: input) }) { [weak self] result in
            if case .success(let note) = result { self?.didChange(note) }
            completion?(result)
        }
    }

    func delete(_ note: Note, completion: ((Bool) -> Void)? = nil) {
        run({ try $0.deleteNote(id: note.id) }) { [weak self] result in
            let deleted = (try? result.get()) ?? false
            if deleted {
                NoteExporter.remove(id: note.id)
                self?.revision += 1
            }
            completion?(deleted)
        }
    }

    /// Put a deleted note back. It gets a new id; the content, tags and pin come back.
    func restore(_ note: Note, completion: ((Result<Note, Error>) -> Void)? = nil) {
        create(NoteInput(title: note.title, bodyMd: note.bodyMd, source: note.source,
                         meetingId: note.meetingId, tags: note.tags, pinned: note.pinned), completion: completion)
    }

    // MARK: - Reading

    /// Pinned first, then most recently edited.
    func notes(limit: UInt32 = 1_000, completion: @escaping ([Note]) -> Void) {
        run({ try $0.notes(limit: limit) }) { completion((try? $0.get()) ?? []) }
    }

    func note(id: Int64, completion: @escaping (Note?) -> Void) {
        notes { completion($0.first { $0.id == id }) }
    }

    func search(_ query: String, completion: @escaping ([SearchHit]) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return completion([]) }
        run({ try $0.search(query: trimmed) }) { completion((try? $0.get()) ?? []) }
    }

    /// A meeting as Markdown, for showing meeting search hits.
    func meetingMarkdown(id: Int64, completion: @escaping (String?) -> Void) {
        run({ try $0.exportMeetingMarkdown(id: id) }) { completion(try? $0.get()) }
    }

    /// Write every note to the export folder. Completes with how many were written.
    func exportAll(completion: @escaping (Result<Int, Error>) -> Void) {
        guard let folder = NoteExporter.folder else { return completion(.success(0)) }
        run({ core -> Int in
            let all = try core.notes(limit: UInt32.max)
            for note in all { try NoteExporter.write(note, to: folder) }
            return all.count
        }, completion: completion)
    }

    /// Write one note's file now, e.g. before revealing it in Finder.
    func export(_ note: Note, completion: @escaping (URL?) -> Void) {
        guard let folder = NoteExporter.folder else { return completion(nil) }
        run({ _ -> URL in
            try NoteExporter.write(note, to: folder)
            return folder.appendingPathComponent(NoteExporter.fileName(for: note))
        }, completion: { completion(try? $0.get()) })
    }

    // MARK: - Private

    private func didChange(_ note: Note) {
        revision += 1
        guard let folder = NoteExporter.folder else { return }
        queue.async {
            do {
                try NoteExporter.write(note, to: folder)
            } catch {
                Log.error("Couldn't export note \(note.id): \(error.localizedDescription)")
            }
        }
    }

    /// Run `work` on the notes queue; `completion` comes back on the main queue.
    private func run<T>(_ work: @escaping (FlowstateEngine) throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        guard let core = engine?.core else { return completion(.failure(NotesError.notReady)) }
        queue.async {
            let result = Result { try work(core) }
            if case .failure(let error) = result { Log.error("Notes: \(error.localizedDescription)") }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

extension NoteSource {
    var label: String {
        switch self {
        case .quick: return "quick"
        case .meeting: return "meeting"
        case .dictation: return "dictation"
        }
    }
}

extension Note {
    /// "# Title", a blank line, then the body.
    var markdown: String {
        let body = bodyMd.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || body.hasPrefix("# ") { return body }
        return "# \(title)\n\n\(body)\n"
    }
}
