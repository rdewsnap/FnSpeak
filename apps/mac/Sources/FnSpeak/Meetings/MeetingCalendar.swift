import EventKit
import Foundation

/// The calendar event happening right now, if any, for a meeting's title and
/// participants. Reads only; never asks for access by itself unless told to.
enum MeetingCalendar {
    struct Event: Equatable {
        let id: String
        let title: String
        let attendees: [String]
        let start: Date
        let end: Date
    }

    private static let store = EKEventStore()

    static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Asks for calendar access if it hasn't been asked yet.
    static func requestAccessIfNeeded(_ completion: @escaping () -> Void) {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return completion() }
        store.requestFullAccessToEvents { _, _ in DispatchQueue.main.async(execute: completion) }
    }

    /// The timed event in progress now; when several overlap, the one that
    /// started most recently.
    static func current(at now: Date = Date()) -> Event? {
        guard hasAccess else { return nil }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-12 * 3600), end: now.addingTimeInterval(60), calendars: nil)
        let candidates = store.events(matching: predicate).filter {
            !$0.isAllDay && $0.startDate <= now.addingTimeInterval(60) && $0.endDate > now
                && $0.availability != .free && $0.status != .canceled && CalendarAccounts.isUsed($0.calendar)
        }
        guard let event = candidates.max(by: { $0.startDate < $1.startDate }) else { return nil }
        return Event(
            id: event.calendarItemIdentifier,
            title: event.title?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Meeting",
            attendees: attendees(of: event),
            start: event.startDate,
            end: event.endDate
        )
    }

    private static func attendees(of event: EKEvent) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for attendee in event.attendees ?? [] where !attendee.isCurrentUser {
            let name = attendee.name?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                ?? attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            if !name.isEmpty, seen.insert(name.lowercased()).inserted { names.append(name) }
        }
        return names
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
