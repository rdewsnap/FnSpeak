import AppKit

/// Copies a note or meeting summary into Apple Notes with AppleScript. The
/// first time, macOS asks whether FnSpeak may control Notes.
enum AppleNotes {
    enum SendError: LocalizedError {
        case notAllowed
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notAllowed:
                return "FnSpeak isn't allowed to control Notes. Turn it on in System Settings → Privacy & Security → Automation → FnSpeak."
            case .failed(let message):
                return "Couldn't send to Apple Notes: \(message)"
            }
        }
    }

    /// Create a note in the folder from settings (made if it's missing), in
    /// the default Notes account.
    static func send(title: String, markdown: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let folder = Preferences.shared.appleNotesFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Notes takes the title from the first line of the body.
        let body = "<h1>\(MarkdownHTML.escape(heading.isEmpty ? "Untitled" : heading))</h1>\n" + MarkdownHTML.html(strippingTitle(markdown, heading))
        let source = script(folder: folder.isEmpty ? "FnSpeak" : folder, body: body)
        // NSAppleScript wants the main thread.
        DispatchQueue.main.async {
            var info: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&info)
            if result != nil { return completion(.success(())) }
            let code = info?[NSAppleScript.errorNumber] as? Int ?? 0
            let message = info?[NSAppleScript.errorMessage] as? String ?? "unknown error"
            Log.error("Apple Notes: \(code) \(message)")
            // -1743: the user said no (or hasn't been asked and can't be).
            completion(.failure(code == -1743 || code == -1744 ? SendError.notAllowed : SendError.failed(message)))
        }
    }

    /// `send`, with an alert if it fails.
    static func sendShowingErrors(title: String, markdown: String, done: ((Bool) -> Void)? = nil) {
        send(title: title, markdown: markdown) { result in
            switch result {
            case .success:
                done?(true)
            case .failure(let error):
                done?(false)
                showAlert(error)
            }
        }
    }

    /// Whether macOS lets FnSpeak add to Notes.
    enum Access {
        case allowed
        /// The user said no. FnSpeak is listed under Automation, switched off.
        case refused
        /// Never asked, or Notes isn't open so macOS won't say. FnSpeak
        /// isn't listed under Automation until it has asked once.
        case unknown
    }

    /// Looks without asking, so it never puts up the macOS prompt.
    static var access: Access {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Notes")
        guard let desc = target.aeDesc else { return .unknown }
        switch AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false) {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .refused
        default: return .unknown
        }
    }

    /// Ask now, with something harmless, instead of waiting for the first
    /// note to be sent. Opens Notes if it isn't running.
    static func requestAccess(completion: @escaping (Access) -> Void) {
        DispatchQueue.main.async {
            var info: NSDictionary?
            let result = NSAppleScript(source: "tell application \"Notes\" to count folders")?.executeAndReturnError(&info)
            if result != nil { return completion(.allowed) }
            let code = info?[NSAppleScript.errorNumber] as? Int ?? 0
            Log.error("Apple Notes access: \(code)")
            completion(code == -1743 ? .refused : .unknown)
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private

    private static func script(folder: String, body: String) -> String {
        let folder = quoted(folder)
        return """
        tell application "Notes"
            tell default account
                if not (exists folder \(folder)) then make new folder with properties {name:\(folder)}
                make new note at folder \(folder) with properties {body:\(quoted(body))}
            end tell
        end tell
        """
    }

    /// An AppleScript string literal.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Markdown that starts with `# <title>` would show the title twice.
    private static func strippingTitle(_ markdown: String, _ title: String) -> String {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, trimmed.hasPrefix("# \(title)") else { return trimmed }
        return String(trimmed.dropFirst(title.count + 2)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func showAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't send to Apple Notes"
        alert.informativeText = error.localizedDescription
        if case SendError.notAllowed = error {
            alert.addButton(withTitle: "Open Automation Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { openAutomationSettings() }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
