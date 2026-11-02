import Foundation

/// Where notes and meetings leave Flowstate: the webhook, the calendar
/// event, and the Markdown export folder. The rest of the app reports what
/// happened here and doesn't need to know which integrations are on.
enum Integrations {
    private static var pendingUpdates: [Int64: DispatchWorkItem] = [:]
    /// The notes editor saves every second or so while typing; the webhook
    /// gets the note once typing stops.
    private static let updateDelay: TimeInterval = 5

    static func noteCreated(_ note: Note) {
        Webhook.post(.noteCreated, data: note.webhookData)
    }

    /// Call on the main queue.
    static func noteUpdated(_ note: Note) {
        pendingUpdates[note.id]?.cancel()
        let work = DispatchWorkItem {
            pendingUpdates[note.id] = nil
            Webhook.post(.noteUpdated, data: note.webhookData)
        }
        pendingUpdates[note.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + updateDelay, execute: work)
    }

    /// A meeting was recorded and summarized (or the summary failed and only
    /// the transcript is there).
    static func meetingFinished(_ meeting: Meeting, core: FlowstateEngine) {
        Webhook.post(.meetingFinished, data: meeting.webhookData)
        let prefs = Preferences.shared
        let folder = NoteExporter.meetingFolder
        let appendToCalendar = prefs.calendarAppendSummary && meeting.calendarEventId != nil
        guard folder != nil || appendToCalendar else { return }
        DispatchQueue.global(qos: .utility).async {
            if appendToCalendar { CalendarNotes.append(meeting) }
            if let folder {
                do {
                    let markdown = try core.exportMeetingMarkdown(id: meeting.id)
                    let url = try NoteExporter.write(meeting, markdown: markdown, to: folder)
                    Log.info("Saved meeting \(meeting.id) to \(url.path)")
                } catch {
                    Log.error("Couldn't save meeting \(meeting.id) as Markdown: \(error.localizedDescription)")
                }
            }
        }
    }
}
