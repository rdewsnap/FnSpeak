import AVFoundation
import AppKit
import Combine
import UniformTypeIdentifiers

/// Runs meetings: starts and stops recording, collects live segments for the
/// window, and wraps the core's meeting calls so none of them block the main
/// thread. Everything published here changes on the main queue.
final class MeetingController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Showing the title and participants before recording.
        case setup
        case starting
        case recording
        /// Stopped; transcribing what's left and writing the summary.
        case processing
    }

    struct Draft: Equatable {
        var title = ""
        var participants: [String] = []
        var calendarEventId: String?
    }

    @Published private(set) var phase = Phase.idle
    @Published var draft = Draft()
    /// The meeting being recorded or processed.
    @Published private(set) var current: Meeting?
    /// Live transcript, sorted by start time.
    @Published private(set) var segments: [Segment] = []
    @Published private(set) var startedAt: Date?
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    /// Why the other side isn't being recorded, when it isn't.
    @Published private(set) var systemAudioNote: String?
    /// The meeting the window shows once recording is over.
    @Published private(set) var finished: Meeting?
    @Published var error: String?
    /// Bumped whenever stored meetings change, so lists reload.
    @Published private(set) var revision = 0

    /// Called when recording starts or stops (for the menu bar icon).
    var onRecordingChange: (() -> Void)?

    var isRecording: Bool { phase == .recording }

    private let engine: EngineController
    private let overlay: Overlay
    private let prefs = Preferences.shared
    private let audio = MeetingAudio()
    private let sink = SegmentSink()
    /// Meeting lifecycle calls, in order. Reads go to a global queue.
    private let queue = DispatchQueue(label: "dev.flowstate.meetings", qos: .userInitiated)
    /// The engine the current meeting was started on.
    private var recordingCore: FlowstateEngine?
    private var subscriptions: Set<AnyCancellable> = []
    private var began = false

    private lazy var window = MeetingWindowController(controller: self)
    private lazy var listWindow = MeetingsListWindowController(controller: self)
    private lazy var detector = MeetingDetector(controller: self)

    init(engine: EngineController, overlay: Overlay) {
        self.engine = engine
        self.overlay = overlay
        super.init()
        sink.controller = self
        audio.onLevel = { [weak self] source, level in
            switch source {
            case .mic: self?.micLevel = level
            case .system: self?.systemLevel = level
            }
        }
        NotificationCenter.default.publisher(for: MeetingAudio.systemAudioStopped)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isRecording else { return }
                self.systemAudioNote = "System audio stopped; only your microphone is being recorded now."
            }
            .store(in: &subscriptions)
    }

    /// Starts the call detector and clears out old transcripts once the engine is up.
    func begin() {
        guard !began else { return }
        began = true
        engine.$status
            .filter { $0 == .ready }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.migrateActionItemsDone()
                self?.purgeOld()
            }
            .store(in: &subscriptions)
        detector.start()
    }

    private var core: FlowstateEngine? { engine.isReady ? engine.core : nil }

    // MARK: - Starting

    /// Start a meeting, or show the one in progress. Prefills the title and
    /// participants from the calendar event happening now.
    func requestStart() {
        guard phase == .idle else { return showWindow() }
        guard core != nil else {
            if case .failed(let message) = engine.status { return overlay.show(.error(Overlay.reason(message))) }
            return overlay.show(.message("Still loading the speech model"))
        }
        switch AVCaptureAuthorization.microphone {
        case .notDetermined:
            return AudioRecorder.requestPermission { [weak self] granted in
                if granted { self?.requestStart() } else { self?.overlay.show(.error("Microphone access is off")) }
            }
        case .denied:
            return overlay.show(.error("Microphone access is off"))
        case .authorized:
            break
        }
        MeetingCalendar.requestAccessIfNeeded { [weak self] in
            guard let self, self.phase == .idle else { return }
            self.draft = Self.draftFromCalendar()
            if self.prefs.meetingAskTitle {
                self.finished = nil
                self.phase = .setup
                self.showWindow()
            } else {
                self.beginRecording()
            }
        }
    }

    func cancelSetup() {
        guard phase == .setup else { return }
        phase = .idle
        window.close()
    }

    /// Start recording with the current draft.
    func beginRecording() {
        guard phase == .idle || phase == .setup, let core else { return }
        phase = .starting
        segments = []
        error = nil
        systemAudioNote = nil
        finished = nil
        var draft = self.draft
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.title.isEmpty { draft.title = Self.defaultTitle() }
        self.draft = draft

        core.setMeetingListener(listener: sink)
        queue.async {
            let result = Result {
                try core.startMeeting(title: draft.title, calendarEventId: draft.calendarEventId, participants: draft.participants)
            }
            DispatchQueue.main.async { self.didStart(result, core: core) }
        }
    }

    private func didStart(_ result: Result<Meeting, Error>, core: FlowstateEngine) {
        let meeting: Meeting
        switch result {
        case .success(let m): meeting = m
        case .failure(let error):
            core.setMeetingListener(listener: nil)
            phase = .idle
            self.error = Self.message(for: error)
            Log.error("Meeting failed to start: \(error.localizedDescription)")
            return showWindow()
        }

        audio.onSamples = { source, samples in core.feedMeetingAudio(source: source, samples: samples) }
        do {
            try audio.startMic()
        } catch {
            Log.error("Meeting: microphone failed to start (\(error.localizedDescription))")
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            phase = .idle
            queue.async {
                _ = try? core.finishMeeting()
                _ = try? core.deleteMeeting(id: meeting.id)
                core.setMeetingListener(listener: nil)
            }
            return showWindow()
        }

        recordingCore = core
        current = meeting
        startedAt = Date()
        phase = .recording
        Log.info("Meeting \(meeting.id) started")
        overlay.showMeeting(since: startedAt!) { [weak self] in self?.showWindow() }
        onRecordingChange?()
        showWindow()

        if prefs.meetingSystemAudio {
            Task { [audio] in
                do {
                    try await audio.startSystemAudio()
                } catch {
                    Log.info("Meeting: \(error.localizedDescription)")
                    await MainActor.run { self.systemAudioNote = error.localizedDescription }
                }
            }
        } else {
            systemAudioNote = "System audio is off in Settings, so only your microphone is recorded."
        }
    }

    // MARK: - Stopping

    /// Stop recording, then transcribe the rest and summarize.
    func stop() {
        guard phase == .recording, let core = recordingCore else { return }
        audio.stop()
        micLevel = 0
        systemLevel = 0
        phase = .processing
        overlay.endMeeting()
        onRecordingChange?()
        let id = current?.id
        queue.async {
            let result = Result { try core.finishMeeting() }
            // On failure the transcript is still saved; show what there is.
            let fallback = (try? result.get()) == nil ? id.flatMap { try? core.meeting(id: $0) } : nil
            DispatchQueue.main.async {
                core.setMeetingListener(listener: nil)
                self.recordingCore = nil
                switch result {
                case .success(let meeting):
                    self.finished = meeting
                    Log.info("Meeting \(meeting.id) summarized")
                    Integrations.meetingFinished(meeting, core: core)
                case .failure(let error):
                    self.error = Self.message(for: error)
                    self.finished = fallback ?? nil
                    Log.error("Meeting finish failed: \(error.localizedDescription)")
                    if let fallback = fallback ?? nil { Integrations.meetingFinished(fallback, core: core) }
                }
                self.current = nil
                self.startedAt = nil
                self.phase = .idle
                self.revision += 1
            }
        }
    }

    @objc func toggleMeeting() {
        isRecording ? stop() : requestStart()
    }

    fileprivate func receive(_ segment: Segment) {
        guard segment.meetingId == current?.id else { return }
        // Segments from the two streams can land slightly out of order.
        let index = segments.firstIndex { $0.startedMs > segment.startedMs } ?? segments.endIndex
        segments.insert(segment, at: index)
    }

    // MARK: - Stored meetings

    func meetings(limit: UInt32 = 500, completion: @escaping ([Meeting]) -> Void) {
        read(completion, fallback: []) { try $0.meetings(limit: limit) }
    }

    func meeting(id: Int64, completion: @escaping (Meeting?) -> Void) {
        read(completion, fallback: nil) { try $0.meeting(id: id) }
    }

    func search(_ query: String, completion: @escaping ([SearchHit]) -> Void) {
        read(completion, fallback: []) { try $0.search(query: query) }
    }

    func resummarize(_ id: Int64, completion: @escaping (Result<Meeting, Error>) -> Void) {
        guard let core else { return completion(.failure(FlowstateError.Meeting("Speech model is still loading"))) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try core.summarizeMeeting(id: id) }
            DispatchQueue.main.async {
                self.revision += 1
                completion(result)
            }
        }
    }

    func delete(_ id: Int64, completion: @escaping (Bool) -> Void) {
        guard let core else { return completion(false) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try core.deleteMeeting(id: id) }
            DispatchQueue.main.async {
                if case .failure(let error) = result { self.error = Self.message(for: error) }
                let deleted = (try? result.get()) ?? false
                if deleted {
                    if self.finished?.id == id { self.finished = nil }
                    self.revision += 1
                }
                completion(deleted)
            }
        }
    }

    /// Save a note against the meeting being recorded.
    func addQuickNote(_ text: String, completion: @escaping (Bool) -> Void) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let core, let meeting = current else { return completion(false) }
        // A given title keeps the cleanup model free for the live transcript.
        let stamp = startedAt.map { Self.timestamp(ms: Int64(Date().timeIntervalSince($0) * 1000)) } ?? ""
        let note = NoteInput(title: "\(meeting.title) — note at \(stamp)", bodyMd: body, source: .meeting,
                             meetingId: meeting.id, tags: ["meeting"], pinned: false)
        DispatchQueue.global(qos: .userInitiated).async {
            let saved = try? core.createNote(note: note)
            DispatchQueue.main.async {
                if let saved { Integrations.noteCreated(saved) }
                completion(saved != nil)
            }
        }
    }

    func export(_ meeting: Meeting) {
        guard let core else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try core.exportMeetingMarkdown(id: meeting.id) }
            DispatchQueue.main.async {
                switch result {
                case .success(let markdown): self.save(markdown, for: meeting)
                case .failure(let error): self.error = Self.message(for: error)
                }
            }
        }
    }

    /// The summary and action items (not the transcript) as a new Apple Note.
    func sendToAppleNotes(_ meeting: Meeting, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let core else { return completion(.failure(FlowstateError.Meeting("Flowstate is still starting up"))) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try core.exportMeetingMarkdown(id: meeting.id) }
            DispatchQueue.main.async {
                switch result {
                case .success(let markdown):
                    let summary = markdown.components(separatedBy: "\n## Transcript").first ?? markdown
                    AppleNotes.send(title: meeting.title, markdown: summary, completion: completion)
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    private func save(_ markdown: String, for meeting: Meeting) {
        let panel = NSSavePanel()
        panel.directoryURL = URL(fileURLWithPath: prefs.meetingExportFolder, isDirectory: true)
        panel.nameFieldStringValue = Self.fileName(for: meeting)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func read<T>(_ completion: @escaping (T) -> Void, fallback: T, _ body: @escaping (FlowstateEngine) throws -> T) {
        guard let core = engine.core else { return completion(fallback) }
        DispatchQueue.global(qos: .userInitiated).async {
            let value = (try? body(core)) ?? fallback
            DispatchQueue.main.async { completion(value) }
        }
    }

    /// Deletes transcripts older than the retention setting.
    private func purgeOld() {
        let days = prefs.meetingRetentionDays
        guard days > 0, let core else { return }
        let cutoff = Int64(Date().timeIntervalSince1970) - Int64(days) * 86_400
        DispatchQueue.global(qos: .utility).async {
            let old = ((try? core.meetings(limit: 100_000)) ?? []).filter { $0.startedAt < cutoff && $0.status != .recording }
            var removed: [Int64] = []
            for meeting in old where (try? core.deleteMeeting(id: meeting.id)) == true { removed.append(meeting.id) }
            guard !removed.isEmpty else { return }
            DispatchQueue.main.async {
                self.revision += 1
                Log.info("Deleted \(removed.count) meeting transcripts older than \(days) days")
            }
        }
    }

    // MARK: - Editing

    func rename(_ id: Int64, to title: String, completion: @escaping (Result<Meeting, Error>) -> Void) {
        edit(completion) { try $0.renameMeeting(id: id, title: title) }
    }

    func setParticipants(_ id: Int64, _ names: [String], completion: @escaping (Result<Meeting, Error>) -> Void) {
        edit(completion) { try $0.updateMeetingParticipants(id: id, participants: names) }
    }

    func setActionItem(_ index: Int, done: Bool, in id: Int64, completion: @escaping (Result<Meeting, Error>) -> Void) {
        edit(completion) { try $0.setActionItemDone(meetingId: id, index: UInt32(index), done: done) }
    }

    private func edit(_ completion: @escaping (Result<Meeting, Error>) -> Void, _ body: @escaping (FlowstateEngine) throws -> Meeting) {
        guard let core = engine.core else { return completion(.failure(FlowstateError.Meeting("Flowstate is still starting up"))) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try body(core) }
            DispatchQueue.main.async {
                if case .success(let meeting) = result {
                    if self.finished?.id == meeting.id { self.finished = meeting }
                    self.revision += 1
                }
                completion(result)
            }
        }
    }

    /// Action items used to be ticked off in UserDefaults (meeting id → done
    /// tasks). Move them into the meetings once, then forget them.
    private func migrateActionItemsDone() {
        let key = "meetingActionItemsDone"
        guard let legacy = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]], let core else { return }
        DispatchQueue.global(qos: .utility).async {
            for (idText, ticked) in legacy {
                guard let id = Int64(idText), let meeting = try? core.meeting(id: id) else { continue }
                for (index, item) in meeting.actionItems.enumerated() {
                    let done = ticked.contains(item.task)
                    if done != item.done { _ = try? core.setActionItemDone(meetingId: id, index: UInt32(index), done: done) }
                }
            }
            DispatchQueue.main.async {
                UserDefaults.standard.removeObject(forKey: key)
                self.revision += 1
                Log.info("Moved ticked action items for \(legacy.count) meetings into the meetings database")
            }
        }
    }

    // MARK: - Windows and menu

    func showWindow() {
        window.show()
    }

    /// The meeting window, showing a stored meeting.
    func show(_ meeting: Meeting) {
        guard phase == .idle else { return showWindow() }
        finished = meeting
        error = nil
        window.show()
    }

    @objc func showList() {
        listWindow.show()
    }

    /// "Start meeting…" or "Stop meeting", and "Meetings…".
    func addMenuItems(to menu: NSMenu) {
        let toggle: NSMenuItem
        switch phase {
        case .recording:
            toggle = NSMenuItem(title: "Stop meeting", action: #selector(toggleMeeting), keyEquivalent: "")
        case .processing:
            toggle = NSMenuItem(title: "Summarizing meeting…", action: nil, keyEquivalent: "")
        case .setup, .starting:
            toggle = NSMenuItem(title: "Start meeting…", action: #selector(showMeetingWindow), keyEquivalent: "")
        case .idle:
            toggle = NSMenuItem(title: "Start meeting…", action: #selector(toggleMeeting), keyEquivalent: "")
        }
        toggle.target = self
        menu.addItem(toggle)
        let list = NSMenuItem(title: "Meetings…", action: #selector(showList), keyEquivalent: "")
        list.target = self
        menu.addItem(list)
    }

    @objc private func showMeetingWindow() {
        showWindow()
    }

    // MARK: - Helpers

    private static func draftFromCalendar() -> Draft {
        guard let event = MeetingCalendar.current() else { return Draft(title: defaultTitle()) }
        return Draft(title: event.title, participants: event.attendees, calendarEventId: event.id)
    }

    static func defaultTitle(_ date: Date = Date()) -> String {
        "Meeting \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    static func message(for error: Error) -> String {
        if let error = error as? FlowstateError {
            switch error {
            case .Setup(let text), .Dictation(let text), .Storage(let text), .Meeting(let text):
                return text.prefix(1).uppercased() + text.dropFirst()
            }
        }
        return error.localizedDescription
    }

    /// "4:05" or "1:02:09".
    static func timestamp(ms: Int64) -> String {
        let total = max(0, ms / 1000)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func speakerName(_ speaker: String) -> String {
        switch speaker.lowercased() {
        case "me": return "Me"
        case "others": return "Others"
        default: return speaker
        }
    }

    static func fileName(for meeting: Meeting) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(meeting.startedAt))
        let day = date.formatted(.iso8601.year().month().day())
        let title = meeting.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        return "\(day) \(title).md"
    }

    /// The transcript as plain text, for copying.
    static func transcriptText(_ meeting: Meeting) -> String {
        if let md = meeting.transcriptMd, !md.isEmpty { return md }
        return meeting.segments
            .map { "[\(timestamp(ms: $0.startedMs))] \(speakerName($0.speaker)): \($0.text)" }
            .joined(separator: "\n")
    }
}

/// Receives segments on the core's thread and hands them to the main queue.
private final class SegmentSink: MeetingListener, @unchecked Sendable {
    weak var controller: MeetingController?

    func segment(segment: Segment) {
        DispatchQueue.main.async { [weak self] in self?.controller?.receive(segment) }
    }
}

/// Microphone permission without importing AVFoundation everywhere.
enum AVCaptureAuthorization {
    case notDetermined, denied, authorized

    static var microphone: AVCaptureAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
}
