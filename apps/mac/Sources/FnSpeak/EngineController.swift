import Foundation

/// Owns the Rust engine. Loading models and dictating both block, so they
/// run on a serial background queue; results come back on the main queue.
final class EngineController: ObservableObject {
    enum Status: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .loading
    @Published private(set) var lastDictation: Dictation?
    @Published private(set) var cleanupWarning: String?
    /// Goes up whenever the dictation history changes, so lists can reload.
    @Published private(set) var historyRevision = 0

    private var engine: FnSpeakEngine?
    private let queue = DispatchQueue(label: "com.fnspeak.engine", qos: .userInitiated)
    private let prefs = Preferences.shared

    var isReady: Bool { status == .ready }

    func load() {
        setLogSink(sink: CoreLogSink())
        status = .loading
        let config: EngineConfig
        do {
            config = try makeConfig()
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        queue.async {
            do {
                let engine = try FnSpeakEngine(config: config)
                _ = try? engine.purgeHistory(olderThanDays: UInt32(max(self.prefs.historyDays, 1)))
                Log.info("Engine ready (\(self.prefs.speechEngine), \(self.prefs.mode))")
                DispatchQueue.main.async {
                    self.engine = engine
                    self.status = .ready
                }
            } catch {
                // Cleanup models are optional: if the configured one won't
                // start, keep dictating with the rule-based filter.
                if config.mode != .filterOnly && config.mode != .raw,
                   let engine = try? FnSpeakEngine(config: Self.withMode(config, .filterOnly)) {
                    DispatchQueue.main.async {
                        self.engine = engine
                        self.status = .ready
                        self.cleanupWarning = Self.cleanupWarning(for: error)
                    }
                    return
                }
                let message = MeetingController.message(for: error)
                Log.error("Engine failed to load: \(message)")
                DispatchQueue.main.async { self.status = .failed(message) }
            }
        }
    }

    /// One line for Home and the menu when cleanup had to fall back.
    private static func cleanupWarning(for error: Error) -> String {
        if ModelLocator.cleanupModel == nil, Preferences.shared.mode == "local" {
            return "Local cleanup needs its model. Using the instant filter until it's downloaded."
        }
        return "The cleanup model didn't start (\(MeetingController.message(for: error))). Using the instant filter."
    }

    /// Free the models and stop the cleanup servers. Called once, as the app
    /// quits; blocks until it's done so nothing is left running.
    func shutdown() {
        guard let engine else { return }
        self.engine = nil
        engine.shutdown()
    }

    /// Re-apply cleanup settings without reloading the speech model.
    func reconfigureCleanup() {
        guard let engine else { return load() }
        let mode = Self.mode(prefs.mode)
        let local = localModel()
        let cloud = cloudConfig()
        queue.async {
            do {
                try engine.configureCleanup(mode: mode, local: local, cloud: cloud)
                DispatchQueue.main.async { self.cleanupWarning = nil }
            } catch {
                try? engine.configureCleanup(mode: .filterOnly, local: nil, cloud: nil)
                DispatchQueue.main.async {
                    self.cleanupWarning = Self.cleanupWarning(for: error)
                }
            }
        }
    }

    func dictate(_ audio: [Float], context: Context, completion: @escaping (Result<Dictation, Error>) -> Void) {
        guard let engine else {
            completion(.failure(FnSpeakError.Setup("Speech model is still loading")))
            return
        }
        // Read per dictation so the setting applies without a reload.
        let send = prefs.allowSendCommand
        queue.async {
            engine.setSendCommand(enabled: send)
            let result = Result { try engine.dictate(audio: audio, context: context) }
            self.deliver(result, completion)
        }
    }

    /// Whether the core has a dictation session running. Only touched on `queue`.
    private var sessionRunning = false

    /// Start a dictation that's transcribed while it's recorded. Returns where
    /// to send the audio as it arrives (from any thread), or nil when the
    /// engine isn't loaded yet.
    func beginDictation(context: Context) -> (([Float]) -> Void)? {
        guard let engine else { return nil }
        queue.async {
            do {
                try engine.beginDictation(context: context)
                self.sessionRunning = true
            } catch {
                Log.error("Couldn't start live transcription: \(error.localizedDescription)")
                self.sessionRunning = false
            }
        }
        return { [queue] samples in
            queue.async {
                do {
                    try engine.pushAudio(samples: samples)
                } catch {
                    // The audio stays in the session; finishing tries it again.
                    Log.error("Live transcription failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Finish the dictation started with `beginDictation`. `audio` is the
    /// whole recording, used if the session couldn't be started.
    func finishDictation(_ audio: [Float], context: Context, completion: @escaping (Result<Dictation, Error>) -> Void) {
        guard let engine else {
            completion(.failure(FnSpeakError.Setup("Speech model is still loading")))
            return
        }
        let send = prefs.allowSendCommand
        queue.async {
            engine.setSendCommand(enabled: send)
            let live = self.sessionRunning
            self.sessionRunning = false
            let result = Result { try live ? engine.finishDictation() : engine.dictate(audio: audio, context: context) }
            self.deliver(result, completion)
        }
    }

    /// Drop the dictation started with `beginDictation`, if any.
    func cancelDictation() {
        guard let engine else { return }
        queue.async {
            self.sessionRunning = false
            engine.cancelDictation()
        }
    }

    private func deliver(_ result: Result<Dictation, Error>, _ completion: @escaping (Result<Dictation, Error>) -> Void) {
        DispatchQueue.main.async {
            if case .success(let d) = result {
                self.lastDictation = d
                self.historyRevision += 1
            }
            completion(result)
        }
    }

    func addTerms(_ terms: [String], source: TermSource, replacing: Bool = true) {
        guard let engine, !terms.isEmpty else { return }
        queue.async {
            _ = replacing ? try? engine.replaceTerms(source: source, terms: terms) : try? engine.addTerms(source: source, terms: terms)
        }
    }

    func terms(completion: @escaping ([Term]) -> Void) {
        guard let engine else { return completion([]) }
        queue.async {
            let terms = Self.logged("reading the vocabulary") { try engine.terms() } ?? []
            DispatchQueue.main.async { completion(terms) }
        }
    }

    func removeTerm(_ term: String) {
        guard let engine else { return }
        queue.async { _ = try? engine.removeTerm(term: term) }
    }

    // MARK: - Snippets

    func snippets(completion: @escaping ([Snippet]) -> Void) {
        guard let engine else { return completion([]) }
        queue.async {
            let all = Self.logged("reading snippets") { try engine.snippets() } ?? []
            DispatchQueue.main.async { completion(all) }
        }
    }

    /// Add a personal snippet, or change the one with `id`. Completes with
    /// the problem to show, or nil when it was saved.
    func saveSnippet(id: String?, trigger: String, text: String, completion: @escaping (String?) -> Void) {
        guard let engine else { return completion("FnSpeak is still loading.") }
        queue.async {
            var problem: String?
            do {
                if let id {
                    _ = try engine.updateSnippet(id: id, trigger: trigger, text: text)
                } else {
                    _ = try engine.addSnippet(trigger: trigger, text: text)
                }
            } catch {
                problem = MeetingController.message(for: error)
            }
            DispatchQueue.main.async { completion(problem) }
        }
    }

    func removeSnippet(id: String, completion: @escaping () -> Void) {
        guard let engine else { return completion() }
        queue.async {
            _ = try? engine.removeSnippet(id: id)
            DispatchQueue.main.async { completion() }
        }
    }

    /// Why `trigger` can't be used for a personal snippet, or nil if it can.
    func snippetTriggerProblem(_ trigger: String, ignoring id: String?, completion: @escaping (String?) -> Void) {
        guard let engine else { return completion(nil) }
        queue.async {
            let problem = engine.validateSnippetTrigger(trigger: trigger, ignoringId: id)
            DispatchQueue.main.async { completion(problem) }
        }
    }

    /// Learn from the user editing a dictation; completes with what was learned.
    func learnFromEdit(inserted: String, edited: String, completion: @escaping ([LearnedCorrection]) -> Void) {
        guard let engine else { return }
        queue.async {
            let learned = (try? engine.learnFromEdit(inserted: inserted, finalText: edited)) ?? []
            DispatchQueue.main.async { completion(learned) }
        }
    }

    func forget(_ corrections: [LearnedCorrection]) {
        guard let engine else { return }
        queue.async {
            for c in corrections { _ = try? engine.forgetCorrection(heard: c.heard, corrected: c.corrected) }
        }
    }

    /// Run a call into the core; a failure is logged and comes back as nil,
    /// so an empty list in the UI always has an explanation in the log.
    private static func logged<T>(_ what: String, _ work: () throws -> T) -> T? {
        do {
            return try work()
        } catch {
            Log.error("Failed \(what): \(MeetingController.message(for: error))")
            return nil
        }
    }

    // MARK: - History

    /// Past dictations, newest first; only those containing `query` if given.
    func history(matching query: String = "", limit: Int, completion: @escaping ([HistoryEntry]) -> Void) {
        guard let engine else { return completion([]) }
        let query = query.trimmingCharacters(in: .whitespaces)
        queue.async {
            let entries = Self.logged("reading history") { try engine.history(query: query.isEmpty ? nil : query, limit: UInt32(limit)) } ?? []
            DispatchQueue.main.async { completion(entries) }
        }
    }

    /// Totals over the kept history, and over the last `days` days.
    func historyStats(recentDays days: Int, completion: @escaping (HistoryStats?) -> Void) {
        guard let engine else { return completion(nil) }
        let since = Int64(Date().timeIntervalSince1970) - Int64(days) * 86_400
        queue.async {
            let stats = Self.logged("reading history totals") { try engine.historyStats(since: since) }
            DispatchQueue.main.async { completion(stats) }
        }
    }

    func deleteHistoryEntry(_ id: Int64) {
        guard let engine else { return }
        queue.async {
            _ = try? engine.deleteHistoryEntry(id: id)
            DispatchQueue.main.async { self.historyRevision += 1 }
        }
    }

    /// Delete history older than `days` (0 deletes everything). Returns how many were removed.
    func purgeHistory(olderThanDays days: Int, completion: @escaping (Int?) -> Void) {
        guard let engine else { return completion(nil) }
        queue.async {
            let removed = try? engine.purgeHistory(olderThanDays: UInt32(max(days, 0)))
            DispatchQueue.main.async {
                self.historyRevision += 1
                completion(removed.map(Int.init))
            }
        }
    }

    func clearVocabulary(completion: @escaping (Int) -> Void) {
        guard let engine else { return completion(0) }
        queue.async {
            let all = (try? engine.terms()) ?? []
            for term in all { _ = try? engine.removeTerm(term: term.text) }
            DispatchQueue.main.async { completion(all.count) }
        }
    }

    func lastRaw() -> String? { engine?.lastRaw() }

    /// The loaded engine, for callers that run on their own queue (notes).
    var core: FnSpeakEngine? { engine }

    // MARK: - Config

    private func makeConfig() throws -> EngineConfig {
        let speech: SpeechEngine
        switch prefs.speechEngine {
        case "parakeet":
            guard let dir = ModelLocator.parakeetModel else { throw SetupError.missingModel("Parakeet") }
            speech = .parakeet(modelDir: dir.path)
        default:
            guard let file = ModelLocator.whisperModel else { throw SetupError.missingModel("Whisper") }
            speech = .whisper(modelPath: file.path)
        }
        return EngineConfig(
            dataDir: ModelLocator.supportDirectory.path,
            speech: speech,
            mode: Self.mode(prefs.mode),
            local: localModel(),
            cloud: cloudConfig(),
            // Looked for when each meeting starts, so a model downloaded
            // later is picked up without reloading the engine.
            speakerModel: (ModelLocator.speakerModel ?? ModelLocator.defaultSpeakerModel).path
        )
    }

    private func localModel() -> LocalModel? {
        guard let server = ModelLocator.llamaServer, let model = ModelLocator.cleanupModel else { return nil }
        return LocalModel(serverBinary: server.path, modelPath: model.path, lightModelPath: ModelLocator.fastCleanupModel?.path,
                          summaryModelPath: ModelLocator.summaryModel?.path,
                          cleanupOnly: ModelLocator.isFineTune(model))
    }

    private func cloudConfig() -> CloudConfig? {
        let provider: CloudProvider
        switch prefs.cloudProvider {
        case .anthropic: provider = .anthropic
        case .groq: provider = .openAiCompatible(baseUrl: "https://api.groq.com/openai/v1")
        case .custom: provider = .openAiCompatible(baseUrl: prefs.customBaseURL)
        case .fnspeak: provider = .fnSpeak(baseUrl: prefs.serverAPIBase)
        }
        let key = prefs.apiKey
        if prefs.cloudProvider != .custom && (key ?? "").isEmpty { return nil }
        let light = prefs.cloudLightModel.trimmingCharacters(in: .whitespaces)
        return CloudConfig(provider: provider, apiKey: key, model: prefs.cloudModel, lightModel: light.isEmpty ? nil : light)
    }

    static func mode(_ value: String) -> Mode {
        switch value {
        case "local": return .local
        case "cloud": return .cloud
        case "raw": return .raw
        default: return .filterOnly
        }
    }

    static func name(of mode: Mode) -> String {
        switch mode {
        case .local: return "local"
        case .cloud: return "cloud"
        case .filterOnly: return "filterOnly"
        case .raw: return "raw"
        }
    }

    private static func withMode(_ config: EngineConfig, _ mode: Mode) -> EngineConfig {
        var copy = config
        copy.mode = mode
        return copy
    }

    enum SetupError: LocalizedError {
        case missingModel(String)
        var errorDescription: String? {
            switch self {
            case .missingModel(let name):
                return "The \(name) speech model isn't downloaded yet."
            }
        }
    }
}

extension Dictation {
    /// What did the cleanup, for the log and the menu.
    var cleanerLabel: String {
        if let cleaner { return cleaner }
        return skippedCleanup ? "nothing to clean up" : "no model"
    }
}
