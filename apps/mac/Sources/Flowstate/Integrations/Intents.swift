import AppIntents

// Actions for the Shortcuts app. They run inside Flowstate, which launches
// if it isn't running.
//
// Shortcuts finds these through Metadata.appintents in the app bundle,
// which Xcode's build writes and `swift build` doesn't. Until the bundle
// step produces it, the flowstate:// links are the dependable way in.

struct StartMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Meeting"
    static let description = IntentDescription("Start recording and transcribing a meeting in Flowstate.")

    @Parameter(title: "Title", description: "Leave empty to use the calendar event happening now.")
    var meetingTitle: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        AppActions.shared.startMeeting(meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        return .result()
    }
}

struct StopMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Meeting"
    static let description = IntentDescription("Stop recording the current meeting and write its summary.")

    @MainActor
    func perform() async throws -> some IntentResult {
        AppActions.shared.stopMeeting()
        return .result()
    }
}

struct CreateNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Note"
    static let description = IntentDescription("Save text as a Flowstate note.")

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw IntentFailure.emptyNote }
        AppActions.shared.createNote(body)
        return .result()
    }
}

struct GetLastDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Last Dictation"
    static let description = IntentDescription("The text of your most recent dictation.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: AppActions.shared.lastDictation ?? "")
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case emptyNote

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyNote: return "There's no text to save."
        }
    }
}

struct FlowstateShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartMeetingIntent(), phrases: ["Start a meeting in \(.applicationName)"],
                    shortTitle: "Start Meeting", systemImageName: "record.circle")
        AppShortcut(intent: StopMeetingIntent(), phrases: ["Stop the meeting in \(.applicationName)"],
                    shortTitle: "Stop Meeting", systemImageName: "stop.circle")
        AppShortcut(intent: CreateNoteIntent(), phrases: ["Create a note in \(.applicationName)"],
                    shortTitle: "Create Note", systemImageName: "note.text.badge.plus")
        AppShortcut(intent: GetLastDictationIntent(), phrases: ["Get my last dictation from \(.applicationName)"],
                    shortTitle: "Last Dictation", systemImageName: "text.quote")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
