import Foundation

/// Passes the Rust core's debug lines (cleanup prompt timings) to the log file.
final class CoreLogSink: LogSink {
    func debug(message: String) { Log.debug(message) }
}
