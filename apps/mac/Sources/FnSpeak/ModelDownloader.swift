import Foundation

/// Downloads the models FnSpeak needs into the models folder, so a fresh
/// install works without the repo's scripts. Nothing is fetched until the
/// user asks for it.
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()

    enum Item: String, CaseIterable, Identifiable {
        case whisper, cleanup, parakeet, speakers

        var id: String { rawValue }

        var title: String {
            switch self {
            case .whisper: return "Speech model (Whisper large-v3-turbo)"
            case .cleanup: return "Cleanup model (Qwen3 4B)"
            case .parakeet: return "Faster speech model (Parakeet)"
            case .speakers: return "Speaker model (CAM++)"
            }
        }

        /// Shown next to the button, so nobody starts 2.5 GB by accident.
        var size: String {
            switch self {
            case .whisper: return "550 MB"
            case .cleanup: return "2.5 GB"
            case .parakeet: return "650 MB"
            case .speakers: return "28 MB"
            }
        }

        var source: String {
            switch self {
            case .whisper, .cleanup: return "huggingface.co"
            case .parakeet, .speakers: return "github.com"
            }
        }

        var url: URL {
            switch self {
            case .whisper:
                return URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!
            case .cleanup:
                return URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!
            case .parakeet:
                return URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2")!
            case .speakers:
                // "recongition" is how the release tag is spelled upstream.
                return URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/\(ModelLocator.speakerModelName)")!
            }
        }

        /// What the download is saved as in the models folder.
        var fileName: String {
            switch self {
            case .whisper: return "ggml-large-v3-turbo-q5_0.bin"
            case .cleanup: return "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
            case .parakeet: return "parakeet.tar.bz2"
            case .speakers: return ModelLocator.speakerModelName
            }
        }

        /// Whether a usable model of this kind is already on disk.
        var isPresent: Bool {
            switch self {
            case .whisper: return ModelLocator.whisperModel != nil
            case .cleanup: return ModelLocator.cleanupModel != nil
            case .parakeet: return ModelLocator.parakeetModel != nil
            case .speakers: return ModelLocator.speakerModel != nil
            }
        }
    }

    enum State: Equatable {
        case idle
        /// 0...1, or nil while the size isn't known yet.
        case downloading(Double?)
        case unpacking
        case failed(String)
    }

    @Published private(set) var states: [Item: State] = [:]
    /// Goes up when a model lands, so views re-check what's on disk.
    @Published private(set) var revision = 0

    /// Called on the main queue when a model is ready to use.
    var onReady: ((Item) -> Void)?

    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var tasks: [Item: URLSessionDownloadTask] = [:]

    func state(_ item: Item) -> State { states[item] ?? .idle }

    var isBusy: Bool {
        states.values.contains { state in
            switch state {
            case .downloading, .unpacking: return true
            case .idle, .failed: return false
            }
        }
    }

    /// The general model is on disk, whichever model does the cleanup.
    static var hasGeneralModel: Bool {
        FileManager.default.fileExists(atPath: ModelLocator.modelsDirectory.appendingPathComponent(Item.cleanup.fileName).path)
    }

    /// Fetch the general model for meeting summaries. It's the same file as
    /// the cleanup download, wanted here even though a cleanup model exists.
    func downloadGeneralModel() {
        guard !Self.hasGeneralModel else { return }
        download(.cleanup, evenIfPresent: true)
    }

    func download(_ item: Item, evenIfPresent: Bool = false) {
        guard tasks[item] == nil, state(item) != .unpacking, evenIfPresent || !item.isPresent else { return }
        let task = session.downloadTask(with: item.url)
        task.taskDescription = item.rawValue
        tasks[item] = task
        states[item] = .downloading(nil)
        Log.info("Downloading \(item.rawValue) model from \(item.source)")
        task.resume()
    }

    func cancel(_ item: Item) {
        tasks[item]?.cancel()
        tasks[item] = nil
        states[item] = .idle
    }

    // MARK: - URLSessionDownloadDelegate

    private func item(for task: URLSessionTask) -> Item? {
        task.taskDescription.flatMap(Item.init(rawValue:))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let item = item(for: downloadTask), tasks[item] === downloadTask else { return }
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
        // Publishing every chunk would redraw far too often.
        if case .downloading(let shown) = state(item), let shown, let fraction, fraction - shown < 0.005 { return }
        states[item] = .downloading(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let item = item(for: downloadTask), tasks[item] === downloadTask else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return fail(item, "The server answered \(http.statusCode).")
        }
        // The temporary file is gone once this returns, so move it now.
        let folder = ModelLocator.modelsDirectory
        let destination = folder.appendingPathComponent(item.fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            return fail(item, error.localizedDescription)
        }
        tasks[item] = nil
        if item == .parakeet {
            unpackParakeet(destination)
        } else {
            finish(item)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let item = item(for: task), tasks[item] === task else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        fail(item, error.localizedDescription)
    }

    private func fail(_ item: Item, _ message: String) {
        tasks[item] = nil
        states[item] = .failed(message)
        Log.error("Downloading \(item.rawValue) model failed: \(message)")
    }

    private func finish(_ item: Item) {
        states[item] = .idle
        revision += 1
        Log.info("Downloaded \(item.rawValue) model")
        onReady?(item)
    }

    /// Parakeet comes as an archive of a folder; unpack it next to the others.
    private func unpackParakeet(_ archive: URL) {
        states[.parakeet] = .unpacking
        let folder = ModelLocator.modelsDirectory
        DispatchQueue.global(qos: .utility).async {
            let scratch = folder.appendingPathComponent("parakeet-unpack", isDirectory: true)
            var problem: String?
            do {
                try? FileManager.default.removeItem(at: scratch)
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let tar = Process()
                tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tar.arguments = ["-xjf", archive.path, "-C", scratch.path]
                try tar.run()
                tar.waitUntilExit()
                guard tar.terminationStatus == 0,
                      let inner = try FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil).first
                else { throw CocoaError(.fileReadCorruptFile) }
                let destination = folder.appendingPathComponent("parakeet-tdt-0.6b-v2", isDirectory: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: inner, to: destination)
            } catch {
                problem = "Couldn't unpack the download."
            }
            try? FileManager.default.removeItem(at: scratch)
            try? FileManager.default.removeItem(at: archive)
            DispatchQueue.main.async {
                if let problem { self.fail(.parakeet, problem) } else { self.finish(.parakeet) }
            }
        }
    }
}
