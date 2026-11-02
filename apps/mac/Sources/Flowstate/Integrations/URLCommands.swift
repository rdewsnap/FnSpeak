import Foundation

/// `flowstate://` links, for Shortcuts, scripts and launchers:
///
///     flowstate://note?text=Buy%20milk     save a note
///     flowstate://meeting/start?title=…    start recording (title optional)
///     flowstate://meeting/stop             stop and summarize
///     flowstate://meeting/open?id=42       show a meeting (calendar links use this)
///     flowstate://dictate                  start or finish a dictation
enum URLCommands {
    enum Command: Equatable {
        case note(String)
        case startMeeting(title: String?)
        case stopMeeting
        case openMeeting(Int64)
        case dictate
    }

    static func parse(_ url: URL) -> Command? {
        guard url.scheme?.lowercased() == "flowstate" else { return nil }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func query(_ name: String) -> String? {
            parts?.queryItems?.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch (host, path) {
        case ("note", ""), ("note", "new"):
            guard let text = query("text"), !text.isEmpty else { return nil }
            return .note(text)
        case ("meeting", "start"):
            let title = query("title")
            return .startMeeting(title: title?.isEmpty == false ? title : nil)
        case ("meeting", "stop"):
            return .stopMeeting
        case ("meeting", "open"):
            return query("id").flatMap(Int64.init).map(Command.openMeeting)
        case ("dictate", ""):
            return .dictate
        default:
            return nil
        }
    }

    /// Run a link. Returns false when it isn't one Flowstate knows.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard Preferences.shared.urlCommandsEnabled else {
            Log.info("Ignored \(url.scheme ?? "")://\(url.host ?? "") link: links are off in Settings")
            return false
        }
        guard let command = parse(url) else {
            Log.info("Unknown link: \(url.absoluteString.prefix(80))")
            return false
        }
        let actions = AppActions.shared
        switch command {
        case .note(let text): actions.createNote(text)
        case .startMeeting(let title): actions.startMeeting(title)
        case .stopMeeting: actions.stopMeeting()
        case .openMeeting(let id): actions.openMeeting(id)
        case .dictate: actions.toggleDictation()
        }
        return true
    }
}
