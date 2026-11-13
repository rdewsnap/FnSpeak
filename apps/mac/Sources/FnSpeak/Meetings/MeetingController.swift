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
    /// The meeting the dock shows once recording is over.
    @Published private(set) var finished: Meeting?
    /// A meeting the Meetings page should select when it next appears.
    @Published var focusMeetingId: Int64?
    @Published var error: String?
    /// The meeting's pad: what the user types while it runs. It belongs to
    /// the meeting, is saved as it's typed, and goes into the summary.
    @Published var pad = "" {
        didSet { if pad != oldValue { padChanged() } }
    }
    /// The meeting the pad belongs to, and a save waiting for typing to pause.
    private var padMeetingId: Int64?
    private var padSave: DispatchWorkItem?
    /// Bumped whenever stored meetings change, so lists reload.
    @Published private(set) var revision = 0

    /// Called when recording starts or stops (for the menu bar icon).
    var onRecordingChange: (() -> Void)?
    /// A call was noticed and nothing is recording: the calendar event it's
    /// during, or one made up for a call that isn't on the calendar. Nil
    /// when a call like that ends.
    var onCallDetected: ((MeetingCalendar.Event?) -> Void)?
    /// FnSpeak itself has the microphone open for a dictation.
    var isDictating: (() -> Bool)?

    var isRecording: Bool { phase == .recording }

    private let engine: EngineController
    private let overlay: Overlay
    private let prefs = Preferences.shared
    private let audio = MeetingAudio()
    private let sink = SegmentSink()
    /// Meeting lifecycle calls, in order. Reads go to a global queue.
    private let queue = DispatchQueue(label: "com.fnspeak.meetings", qos: .userInitiated)
    /// The engine the current meeting was started on.
    private var recordingCore: FnSpeakEngine?
    private var subscriptions: Set<AnyCancellable> = []
    private var began = false

    /// Where a meeting is shown: docked to the side of the screen.
    private lazy var dock = MeetingDock(controller: self)
    /// Set by the app: put the main window away while the meeting is docked.
    var hideApp: (() -> Void)?
    private lazy var listWindow = MeetingsListWindowController(controller: self)
    /// Set by the app: show the Meetings page in the main window.
    var showLibrary: (() -> Void)?
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

    private var core: FnSpeakEngine? { engine.isReady ? engine.core : nil }

    // MARK: - Starting

    /// Start a meeting, or show the one in progress. Prefills the title and
    /// participants from the calendar event happening now.
    /// With a title (from a link or Shortcut) recording starts straight
    /// away, without asking.
    func requestStart(title: String? = nil) {
        guard phase == .idle else { return dock.show() }
        guard core != nil else {
            if case .failed(let message) = engine.status { return overlay.show(.error(Overlay.reason(message))) }
            return overlay.show(.message("Still loading the speech model"))
        }
        switch AVCaptureAuthorization.microphone {
        case .notDetermined:
            return AudioRecorder.requestPermission { [weak self] granted in
                if granted { self?.requestStart(title: title) } else { self?.overlay.show(.error("Microphone access is off")) }
            }
        case .denied:
            return overlay.show(.error("Microphone access is off"))
        case .authorized:
            break
        }
        MeetingCalendar.requestAccessIfNeeded { [weak self] in
            guard let self, self.phase == .idle else { return }
            self.draft = Self.draftFromCalendar()
            if let title { self.draft.title = title }
            if self.prefs.meetingAskTitle && title == nil {
                self.finished = nil
                self.error = nil
                self.phase = .setup
                self.hideApp?()
                self.dock.show()
            } else {
                self.beginRecording()
            }
        }
    }

    func cancelSetup() {
        guard phase == .setup else { return }
        phase = .idle
    }

    /// Start recording with the current draft.
    func beginRecording() {
        guard phase == .idle || phase == .setup, let core else { return }
        phase = .starting
        segments = []
        error = nil
        systemAudioNote = nil
        finished = nil
        padMeetingId = nil
        pad = ""
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

    private func didStart(_ result: Result<Meeting, Error>, core: FnSpeakEngine) {
        let meeting: Meeting
        switch result {
        case .success(let m): meeting = m
        case .failure(let error):
            core.setMeetingListener(listener: nil)
            phase = .idle
            self.error = Self.message(for: error)
            Log.error("Meeting failed to start: \(error.localizedDescription)")
            return dock.show()
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
            return dock.show()
        }

        recordingCore = core
        current = meeting
        padMeetingId = meeting.id
        startedAt = Date()
        phase = .recording
        Log.info("Meeting \(meeting.id) started")
        // The pill shows it's recording; clicking it folds the dock in and out.
        overlay.showMeeting(since: startedAt!) { [weak self] in self?.dock.toggle() }
        onRecordingChange?()
        hideApp?()
        dock.show(tab: .transcript)

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
        // Stopped from anywhere, the summary turns up in the dock.
        dock.show(tab: .summary)
        let id = current?.id
        // The pad has to be on the meeting before the summary is written.
        padSave?.cancel()
        let pad = self.pad
        queue.async {
            if let id { try? core.setMeetingNotes(id: id, notes: pad) }
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

    /// Meetings changed outside this controller (a sync pulled some); reload lists.
    func reloadAfterSync() { revision += 1 }

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
        guard let core else { return completion(.failure(FnSpeakError.Meeting("Speech model is still loading"))) }
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

    /// Save a stored meeting's pad, edited after the fact. Calls back once
    /// it's written, so a summary asked for next reads the new text.
    func saveNotes(_ id: Int64, _ text: String, completion: (() -> Void)? = nil) {
        guard let core = engine.core else { completion?(); return }
        // The dock may be showing the same meeting; keep its pad in step.
        if id == padMeetingId, pad != text {
            padSave?.cancel()
            padMeetingId = nil
            pad = text
            padMeetingId = id
        }
        queue.async {
            try? core.setMeetingNotes(id: id, notes: text)
            DispatchQueue.main.async { completion?() }
        }
    }

    /// Save the pad a moment after the typing stops.
    private func padChanged() {
        padSave?.cancel()
        guard let id = padMeetingId, let core = engine.core else { return }
        let text = pad
        let save = DispatchWorkItem { [weak self] in
            self?.queue.async { try? core.setMeetingNotes(id: id, notes: text) }
        }
        padSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: save)
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
        guard let core else { return completion(.failure(FnSpeakError.Meeting("FnSpeak is still starting up"))) }
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

    /// Show a stored meeting by id, e.g. from a fnspeak:// link.
    func open(id: Int64) {
        meeting(id: id) { [weak self] found in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            if let found { self.showInApp(found.id) } else { self.showList() }
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

    private func read<T>(_ completion: @escaping (T) -> Void, fallback: T, _ body: @escaping (FnSpeakEngine) throws -> T) {
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

    private func edit(_ completion: @escaping (Result<Meeting, Error>) -> Void, _ body: @escaping (FnSpeakEngine) throws -> Meeting) {
        guard let core = engine.core else { return completion(.failure(FnSpeakError.Meeting("FnSpeak is still starting up"))) }
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

    /// For DevTools: stand in a phase without recording anything, so the dock can be drawn.
    func preview(_ phase: Phase) {
        draft = Draft(title: "Weekly product sync", participants: ["Ana", "Sam", "Priya"])
        startedAt = phase == .recording ? Date().addingTimeInterval(-754) : nil
        self.phase = phase
    }

    /// The Meetings page of the main window, on this meeting if there is one.
    func showInApp(_ id: Int64?) {
        if let id { focusMeetingId = id }
        showList()
    }

    @objc func showList() {
        if let showLibrary { showLibrary() } else { listWindow.show() }
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
            toggle = NSMenuItem(title: "Start meeting…", action: #selector(showDock), keyEquivalent: "")
        case .idle:
            toggle = NSMenuItem(title: "Start meeting…", action: #selector(toggleMeeting), keyEquivalent: "")
        }
        toggle.target = self
        menu.addItem(toggle)
        let list = NSMenuItem(title: "Meetings…", action: #selector(showList), keyEquivalent: "")
        list.target = self
        menu.addItem(list)
    }

    @objc private func showDock() {
        dock.show()
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
        if let error = error as? FnSpeakError {
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
