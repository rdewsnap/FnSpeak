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

    private var engine: FlowstateEngine?
    private let queue = DispatchQueue(label: "dev.flowstate.engine", qos: .userInitiated)
    private let prefs = Preferences.shared

    var isReady: Bool { status == .ready }

    func load() {
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
                let engine = try FlowstateEngine(config: config)
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
                   let engine = try? FlowstateEngine(config: Self.withMode(config, .filterOnly)) {
                    DispatchQueue.main.async {
                        self.engine = engine
                        self.status = .ready
                        self.cleanupWarning = "Cleanup model unavailable (\(error.localizedDescription)). Using filter only."
                    }
                    return
                }
                Log.error("Engine failed to load: \(error.localizedDescription)")
                DispatchQueue.main.async { self.status = .failed(error.localizedDescription) }
            }
        }
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
                    self.cleanupWarning = "Cleanup model unavailable (\(error.localizedDescription)). Using filter only."
                }
            }
        }
    }

    func dictate(_ audio: [Float], context: Context, completion: @escaping (Result<Dictation, Error>) -> Void) {
        guard let engine else {
            completion(.failure(FlowstateError.Setup("Speech model is still loading")))
            return
        }
        queue.async {
            let result = Result { try engine.dictate(audio: audio, context: context) }
            DispatchQueue.main.async {
                if case .success(let d) = result { self.lastDictation = d }
                completion(result)
            }
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
            let terms = (try? engine.terms()) ?? []
            DispatchQueue.main.async { completion(terms) }
        }
    }

    func removeTerm(_ term: String) {
        guard let engine else { return }
        queue.async { _ = try? engine.removeTerm(term: term) }
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

    /// Delete history older than `days` (0 deletes everything). Returns how many were removed.
    func purgeHistory(olderThanDays days: Int, completion: @escaping (Int?) -> Void) {
        guard let engine else { return completion(nil) }
        queue.async {
            let removed = try? engine.purgeHistory(olderThanDays: UInt32(max(days, 0)))
            DispatchQueue.main.async { completion(removed.map(Int.init)) }
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
            cloud: cloudConfig()
        )
    }

    private func localModel() -> LocalModel? {
        guard let server = ModelLocator.llamaServer, let model = ModelLocator.cleanupModel else { return nil }
        return LocalModel(serverBinary: server.path, modelPath: model.path)
    }

    private func cloudConfig() -> CloudConfig? {
        let provider: CloudProvider
        switch prefs.cloudProvider {
        case .anthropic: provider = .anthropic
        case .groq: provider = .openAiCompatible(baseUrl: "https://api.groq.com/openai/v1")
        case .custom: provider = .openAiCompatible(baseUrl: prefs.customBaseURL)
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
                return "No \(name) model found in \(ModelLocator.modelsDirectory.path). Run scripts/fetch-models.sh."
            }
        }
    }
}
