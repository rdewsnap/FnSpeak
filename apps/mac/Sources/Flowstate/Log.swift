import Foundation

/// A small rolling log file at ~/Library/Logs/Flowstate. It records what the
/// app did and how long it took, never what you said.
enum Log {
    enum Level: Int {
        case error = 0, info, debug

        init(setting: String) {
            switch setting {
            case "error": self = .error
            case "debug": self = .debug
            default: self = .info
            }
        }

        var tag: String {
            switch self {
            case .error: return "ERROR"
            case .info: return "INFO"
            case .debug: return "DEBUG"
            }
        }
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Flowstate", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("flowstate.log") }

    private static let queue = DispatchQueue(label: "dev.flowstate.log", qos: .utility)
    private static let maxBytes = 1_000_000

    static func error(_ message: @autoclosure () -> String) { write(.error, message()) }
    static func info(_ message: @autoclosure () -> String) { write(.info, message()) }
    static func debug(_ message: @autoclosure () -> String) { write(.debug, message()) }

    private static func write(_ level: Level, _ message: String) {
        guard level.rawValue <= Level(setting: Preferences.shared.logLevel).rawValue else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level.tag)] \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > maxBytes {
                let old = directory.appendingPathComponent("flowstate.log.1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: fileURL, to: old)
            }
            if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
