import AppKit
import Foundation

/// Bundles logs, settings and a system summary into a zip to attach to a bug
/// report. API keys and dictated text are never included.
enum Diagnostics {
    enum ExportError: LocalizedError {
        case zipFailed
        var errorDescription: String? { "Couldn't create the zip file." }
    }

    /// Builds the zip on a background queue; `completion` runs on the main queue.
    static func export(to destination: URL, engineStatus: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let snapshot = settingsSnapshot()
        let system = systemSummary(engineStatus: engineStatus)
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try build(settings: snapshot, system: system, destination: destination) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func build(settings: [String: Any], system: String, destination: URL) throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("Flowstate-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        for name in ["flowstate.log", "flowstate.log.1"] {
            let source = Log.directory.appendingPathComponent(name)
            if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: folder.appendingPathComponent(name)) }
        }
        let json = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: folder.appendingPathComponent("settings.json"))
        try system.write(to: folder.appendingPathComponent("system.txt"), atomically: true, encoding: .utf8)

        try? fm.removeItem(at: destination)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", folder.path, destination.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw ExportError.zipFailed }
    }

    // MARK: - Contents

    /// Preferences with nothing secret in them: the API key is reduced to
    /// whether one is set, and URLs lose credentials and queries.
    private static func settingsSnapshot() -> [String: Any] {
        let prefs = Preferences.shared
        return [
            "mode": prefs.mode,
            "speechEngine": prefs.speechEngine,
            "cloudProvider": prefs.cloudProvider.rawValue,
            "cloudModel": prefs.cloudModel,
            "cloudLightModel": prefs.cloudLightModel,
            "customEndpoint": redacted(prefs.customBaseURL),
            "apiKeySet": !(prefs.apiKey ?? "").isEmpty,
            "hotkey": prefs.hotkey.displayName,
            "triggerStyle": prefs.triggerStyle,
            "escapeCancels": prefs.escapeCancels,
            "autoStopEnabled": prefs.autoStopEnabled,
            "autoStopSeconds": prefs.autoStopSeconds,
            "customMicrophoneSelected": !prefs.microphoneId.isEmpty,
            "overlayPosition": prefs.overlayPosition,
            "overlaySize": prefs.overlaySize,
            "soundsEnabled": prefs.soundsEnabled,
            "showInMenuBar": prefs.showInMenuBar,
            "showInDock": prefs.showInDock,
            "historyDays": prefs.historyDays,
            "indexContacts": prefs.indexContacts,
            "indexCalendar": prefs.indexCalendar,
            "readFocusedField": prefs.readFocusedField,
            "learnFromCorrections": prefs.learnFromCorrections,
            "projectsFolder": prefs.projectsFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
            "excludedApps": prefs.excludedApps,
            "insertionOverrides": prefs.insertionOverrides,
            "categoryStyles": prefs.categoryStyles,
            "styleOverrides": prefs.styleOverrides,
            "logLevel": prefs.logLevel,
        ]
    }

    private static func redacted(_ urlString: String) -> String {
        guard var parts = URLComponents(string: urlString) else { return "(unparseable)" }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? "(unparseable)"
    }

    private static func systemSummary(engineStatus: String) -> String {
        let hardware = detectHardware()
        let models = (try? FileManager.default.contentsOfDirectory(atPath: ModelLocator.modelsDirectory.path)) ?? []
        return """
        Flowstate \(AppInfo.version) (\(AppInfo.build))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Memory: \(String(format: "%.0f", hardware.totalMemoryGb)) GB, \(hardware.appleSilicon ? "Apple silicon" : "Intel")
        Recommended mode: \(EngineController.name(of: hardware.recommendedMode))
        Engine: \(engineStatus)
        Microphone permission: \(AudioRecorder.hasPermission ? "granted" : "not granted")
        Accessibility permission: \(ContextReader.requestAccessibility(prompt: false) ? "granted" : "not granted")
        llama-server: \(ModelLocator.llamaServer != nil ? "found" : "not found")
        Models folder: \(models.sorted().joined(separator: ", "))
        """
    }
}
