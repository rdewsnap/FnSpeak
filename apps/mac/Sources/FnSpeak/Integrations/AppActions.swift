import Foundation

/// What fnspeak:// links and Shortcuts can ask the app to do. The app
/// delegate fills these in at launch; everything runs on the main queue.
final class AppActions {
    static let shared = AppActions()

    var toggleDictation: () -> Void = {}
    /// Title, or nil for the calendar event happening now.
    var startMeeting: (String?) -> Void = { _ in }
    var stopMeeting: () -> Void = {}
    var openMeeting: (Int64) -> Void = { _ in }
    var isRecordingMeeting: () -> Bool = { false }

    func createNote(_ text: String, completion: ((Result<Note, Error>) -> Void)? = nil) {
        NotesStore.shared.create(text: text, source: .quick, completion: completion)
    }

    var lastDictation: String? {
        RecentDictations.shared.items.first?.text
    }
}
