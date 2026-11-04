import Foundation

/// Finds model files and the llama-server binary. Models live in
/// ~/Library/Application Support/FnSpeak/Models (scripts/fetch-models.sh
/// puts them there).
enum ModelLocator {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FnSpeak", isDirectory: true)
    }

    static var modelsDirectory: URL { supportDirectory.appendingPathComponent("Models", isDirectory: true) }

    /// First `ggml-*.bin` Whisper model, preferring large-v3-turbo.
    static var whisperModel: URL? {
        let files = contents(of: modelsDirectory).filter { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }
        return files.first { $0.lastPathComponent.contains("large-v3-turbo") } ?? files.first
    }

    /// A Parakeet sherpa-onnx export: a folder with tokens.txt and an encoder.
    static var parakeetModel: URL? {
        contents(of: modelsDirectory).first { dir in
            dir.lastPathComponent.lowercased().contains("parakeet")
                && FileManager.default.fileExists(atPath: dir.appendingPathComponent("tokens.txt").path)
        }
    }

    /// The cleanup model: a FnSpeak fine-tune if present, else any GGUF.
    static var cleanupModel: URL? {
        let files = contents(of: modelsDirectory).filter { $0.pathExtension == "gguf" }
        return files.first { $0.lastPathComponent.lowercased().contains("fnspeak") } ?? files.first
    }

    /// UserDefaults key for the file name of the fast model, chosen in
    /// Settings → Advanced.
    static let fastModelKey = "fastCleanupModel"

    /// GGUFs that could serve as the fast model: everything but the main one.
    static var fastModelCandidates: [URL] {
        let main = cleanupModel
        return contents(of: modelsDirectory).filter { $0.pathExtension == "gguf" && $0 != main }
    }

    /// The fast model for simple dictations, if one is chosen and still on disk.
    static var fastCleanupModel: URL? {
        guard let name = UserDefaults.standard.string(forKey: fastModelKey), !name.isEmpty else { return nil }
        return fastModelCandidates.first { $0.lastPathComponent == name }
    }

    /// Bundled in the app's Resources, else Homebrew's.
    static var llamaServer: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("llama-server"),
            URL(fileURLWithPath: "/opt/homebrew/bin/llama-server"),
            URL(fileURLWithPath: "/usr/local/bin/llama-server"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func contents(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }
}
