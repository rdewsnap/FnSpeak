import EventKit
import Foundation

/// Appends a short summary and a link back to FnSpeak to the notes of the
/// calendar event a meeting was recorded for. Needs full calendar access,
/// which meetings already ask for.
enum CalendarNotes {
    private static let store = EKEventStore()

    static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static func link(for meeting: Meeting) -> String {
        "fnspeak://meeting/open?id=\(meeting.id)"
    }

    /// Does nothing without an event id or access, or if this meeting's
    /// line is already there.
    static func append(_ meeting: Meeting) {
        guard let eventId = meeting.calendarEventId, hasAccess, let event = occurrence(eventId, near: meeting.startedAt) else { return }
        let link = link(for: meeting)
        let existing = event.notes ?? ""
        guard !existing.contains(link) else { return }
        let block = text(for: meeting, link: link)
        event.notes = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? block : existing + "\n\n" + block
        do {
            try store.save(event, span: .thisEvent, commit: true)
            Log.info("Added meeting \(meeting.id) to its calendar event")
        } catch {
            Log.error("Couldn't update the calendar event: \(error.localizedDescription)")
        }
    }

    /// The occurrence of a (possibly repeating) event closest to when the
    /// meeting started.
    private static func occurrence(_ id: String, near startedAt: Int64) -> EKEvent? {
        let start = Date(timeIntervalSince1970: TimeInterval(startedAt))
        let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-12 * 3600),
                                                 end: start.addingTimeInterval(12 * 3600), calendars: nil)
        let matches = store.events(matching: predicate).filter { $0.calendarItemIdentifier == id }
        if let best = matches.min(by: { abs($0.startDate.timeIntervalSince(start)) < abs($1.startDate.timeIntervalSince(start)) }) {
            return best
        }
        return store.calendarItem(withIdentifier: id) as? EKEvent
    }

    /// "FnSpeak notes: <first lines of the summary>" and the link.
    static func text(for meeting: Meeting, link: String) -> String {
        var lines = ["FnSpeak notes:"]
        let summary = summaryLines(meeting.summaryMd ?? "")
        lines += summary.prefix(4)
        let open = meeting.actionItems.filter { !$0.done }.count
        if open > 0 { lines.append(open == 1 ? "1 action item" : "\(open) action items") }
        lines.append(link)
        return lines.joined(separator: "\n")
    }

    /// The bullets of the Summary section, without Markdown marks.
    private static func summaryLines(_ md: String) -> [String] {
        var inSummary = false
        var lines: [String] = []
        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                inSummary = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased().hasPrefix("summary")
                continue
            }
            guard inSummary, !line.isEmpty else { continue }
            let text = line.hasPrefix("- ") || line.hasPrefix("* ") ? "• " + line.dropFirst(2) : line
            lines.append(text.replacingOccurrences(of: "**", with: ""))
        }
        return lines
    }
}
