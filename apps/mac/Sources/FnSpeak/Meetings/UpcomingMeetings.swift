import AppKit
import Combine
import EventKit
import Foundation

/// A meeting on the calendar that's on now or coming up, with the link to
/// join it when the event has one.
struct UpcomingMeeting: Equatable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let joinURL: URL?

    /// "Zoom", "Google Meet"… for the button, or nil without a link.
    var service: String? { joinURL.flatMap(JoinLink.service) }

    func isNow(at now: Date = Date()) -> Bool { start <= now.addingTimeInterval(60) && end > now }

    /// "now", "in 12 min" or "2:30 PM".
    func when(at now: Date = Date()) -> String {
        if isNow(at: now) { return "now" }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 60 { return "in \(minutes) min" }
        return start.formatted(date: .omitted, time: .shortened)
    }
}

/// Finding the video call link in a calendar event. Calendars put it in the
/// URL field, the location or the notes, depending on who made the invite.
enum JoinLink {
    private static let hosts: [(match: String, name: String)] = [
        ("zoom.us/", "Zoom"), ("zoomgov.com/", "Zoom"),
        ("meet.google.com/", "Google Meet"),
        ("teams.microsoft.com/", "Teams"), ("teams.live.com/", "Teams"),
        ("webex.com/", "Webex"),
        ("facetime.apple.com/", "FaceTime"),
        ("whereby.com/", "Whereby"),
        ("chime.aws/", "Chime"),
        ("gotomeeting.com/", "GoTo"), ("meet.goto.com/", "GoTo"),
        ("around.co/", "Around"),
        ("slack.com/huddle", "Slack"),
    ]

    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#)

    /// The first call link in any of the given fields, checked in order.
    static func find(in fields: [String?]) -> URL? {
        for field in fields {
            guard let text = field, !text.isEmpty else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in urlPattern.matches(in: text, range: range) {
                guard let r = Range(match.range, in: text) else { continue }
                // Invites wrap links in punctuation; a trailing dot or comma isn't part of one.
                let candidate = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;>"))
                if isCall(candidate), let url = URL(string: candidate) { return url }
            }
        }
        return nil
    }

    private static func isCall(_ link: String) -> Bool {
        let lower = link.lowercased()
        // zoom.us is also Zoom's website; only meeting paths count.
        if lower.contains("zoom.us/") || lower.contains("zoomgov.com/") {
            return ["/j/", "/my/", "/w/", "/s/"].contains { lower.contains($0) }
        }
        return hosts.contains { lower.contains($0.match) }
    }

    static func service(_ url: URL) -> String? {
        let lower = url.absoluteString.lowercased()
        return hosts.first { lower.contains($0.match) }?.name
    }
}

extension MeetingCalendar {
    private static let upcomingStore = EKEventStore()

    /// Timed events that are on now or start within `hours`, soonest first.
    /// Cancelled and declined ones are left out, and so are events marked free.
    static func upcoming(within hours: Double = 8, limit: Int = 3, at now: Date = Date()) -> [UpcomingMeeting] {
        guard hasAccess else { return [] }
        let predicate = upcomingStore.predicateForEvents(
            withStart: now.addingTimeInterval(-12 * 3600), end: now.addingTimeInterval(hours * 3600), calendars: nil)
        return upcomingStore.events(matching: predicate)
            .filter { event in
                !event.isAllDay && event.endDate > now && event.status != .canceled && event.availability != .free
                    && CalendarAccounts.isUsed(event.calendar)
                    && !(event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { event in
                UpcomingMeeting(
                    id: event.calendarItemIdentifier + "@\(Int(event.startDate.timeIntervalSince1970))",
                    title: (event.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "Meeting" : event.title.trimmingCharacters(in: .whitespaces),
                    start: event.startDate,
                    end: event.endDate,
                    joinURL: JoinLink.find(in: [event.url?.absoluteString, event.location, event.notes])
                )
            }
    }
}

/// Keeps the next few meetings current for the window and the menu.
final class UpcomingMeetings: ObservableObject {
    static let shared = UpcomingMeetings()

    @Published private(set) var meetings: [UpcomingMeeting] = []
    /// What's left of today: on now or still to come before midnight.
    @Published private(set) var today: [UpcomingMeeting] = []
    @Published private(set) var hasCalendarAccess = MeetingCalendar.hasAccess

    private var timer: Timer?
    private var observer: NSObjectProtocol?

    /// The meeting worth putting in front of the user: one that's on now,
    /// or the next one if it starts within the hour.
    var next: UpcomingMeeting? {
        let now = Date()
        return meetings.first { $0.isNow(at: now) || $0.start.timeIntervalSince(now) <= 3600 }
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        // For development: draw the app with a meeting about to start.
        if ProcessInfo.processInfo.environment["FNSPEAK_PREVIEW_MEETING"] != nil {
            hasCalendarAccess = true
            meetings = [UpcomingMeeting(id: "preview", title: "Weekly sync", start: Date().addingTimeInterval(8 * 60),
                                        end: Date().addingTimeInterval(38 * 60),
                                        joinURL: URL(string: "https://us02web.zoom.us/j/8123456789"))]
            today = meetings
            return
        }
        let access = MeetingCalendar.hasAccess
        // Reading the calendar can take a moment with many accounts.
        DispatchQueue.global(qos: .utility).async {
            let found = access ? MeetingCalendar.upcoming() : []
            let now = Date()
            let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
            let rest = access ? MeetingCalendar.upcoming(within: midnight.timeIntervalSince(now) / 3600, limit: 6, at: now) : []
            DispatchQueue.main.async {
                if self.hasCalendarAccess != access { self.hasCalendarAccess = access }
                if self.today != rest { self.today = rest }
                if self.meetings != found { self.meetings = found }
            }
        }
    }

    /// Ask macOS for the calendar, or open its settings if that was refused.
    func connectCalendar() {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            MeetingCalendar.requestAccessIfNeeded { [weak self] in self?.refresh() }
        } else if !MeetingCalendar.hasAccess,
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Where Google, Microsoft and other calendar accounts are added to macOS.
    static func openInternetAccounts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
