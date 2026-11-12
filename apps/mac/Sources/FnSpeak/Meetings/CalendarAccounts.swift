import AppKit
import Combine
import EventKit
import Foundation

/// A calendar account macOS knows about, sorted into the service people
/// think of it as.
struct CalendarAccount: Equatable, Identifiable {
    enum Service: Equatable {
        case google, outlook
        /// iCloud, calendars kept on this Mac, and other servers.
        case other
    }

    /// The account's id in EventKit, which survives renames.
    let id: String
    let service: Service
    /// The address the account signs in with when it can be told, or its name.
    let label: String
    let calendars: Int
}

/// Which calendar accounts are on this Mac. FnSpeak reads calendars through
/// macOS, so "connecting" one means adding the account in System Settings
/// and letting FnSpeak read calendars; nothing is fetched over the network.
enum CalendarAccounts {
    private static let store = EKEventStore()

    static func all() -> [CalendarAccount] {
        guard MeetingCalendar.hasAccess else { return [] }
        return store.sources.compactMap { source in
            let titles = source.calendars(for: .event).map(\.title)
            guard !titles.isEmpty, let kind = kind(of: source.sourceType) else { return nil }
            let (service, label) = classify(kind: kind, title: source.title, calendars: titles)
            return CalendarAccount(id: source.sourceIdentifier, service: service, label: label, calendars: titles.count)
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// What kind of server an account talks to, as far as it matters here.
    enum Kind {
        case exchange, calDAV, onThisMac
    }

    private static func kind(of type: EKSourceType) -> Kind? {
        switch type {
        case .exchange: return .exchange
        case .calDAV, .mobileMe: return .calDAV
        case .local: return .onThisMac
        // Birthdays and subscribed feeds aren't accounts anyone connects.
        case .birthdays, .subscribed: return nil
        @unknown default: return nil
        }
    }

    /// EventKit doesn't say which company is behind an account, so this goes
    /// by what each one reliably looks like. Outlook and Microsoft 365 are
    /// the Exchange accounts. Google is the CalDAV account named for Google,
    /// or whose main calendar is named after an email address, which is how
    /// Google names it.
    static func classify(kind: Kind, title: String, calendars: [String]) -> (CalendarAccount.Service, String) {
        let address = ([title] + calendars).first(where: isEmail)
        switch kind {
        case .exchange:
            return (.outlook, address ?? title)
        case .onThisMac:
            return (.other, "On this Mac")
        case .calDAV:
            let lower = title.lowercased()
            if lower.contains("icloud") { return (.other, title) }
            if lower.contains("google") || lower.contains("gmail") || calendars.contains(where: isEmail) {
                return (.google, address ?? title)
            }
            return (.other, title)
        }
    }

    private static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !text.contains(" ")
    }

    /// Whether events from this calendar should be used. Accounts can be
    /// switched off on the Connectors page without removing them from macOS.
    static func isUsed(_ calendar: EKCalendar?) -> Bool {
        guard let id = calendar?.source?.sourceIdentifier else { return true }
        return !Preferences.shared.calendarIgnoredAccounts.contains(id)
    }
}

/// Keeps the list of calendar accounts current for the Connectors page.
final class CalendarAccountList: ObservableObject {
    static let shared = CalendarAccountList()

    enum Access: Equatable {
        case notAsked, allowed, refused
    }

    @Published private(set) var accounts: [CalendarAccount] = []
    @Published private(set) var access: Access = .notAsked

    private var observers: [NSObjectProtocol] = []

    func start() {
        refresh()
        guard observers.isEmpty else { return }
        // An account added in System Settings shows up as a store change,
        // and at the latest when the user comes back to FnSpeak.
        for name in [Notification.Name.EKEventStoreChanged, NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
    }

    func refresh() {
        // For development: draw the page with made-up accounts.
        if let preview = ProcessInfo.processInfo.environment["FNSPEAK_PREVIEW_CALENDARS"] {
            access = preview == "refused" ? .refused : .allowed
            accounts = preview == "refused" ? [] : [
                CalendarAccount(id: "preview-google", service: .google, label: "sam@example.com", calendars: 3),
                CalendarAccount(id: "preview-icloud", service: .other, label: "iCloud", calendars: 2),
            ]
            return
        }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: access = .notAsked
        case .fullAccess: access = .allowed
        default: access = .refused
        }
        DispatchQueue.global(qos: .utility).async {
            let found = CalendarAccounts.all()
            DispatchQueue.main.async {
                if self.accounts != found { self.accounts = found }
            }
        }
    }

    func accounts(for service: CalendarAccount.Service) -> [CalendarAccount] {
        accounts.filter { $0.service == service }
    }

    /// The next step towards a connected calendar: ask macOS for calendars,
    /// open the setting that was refused, or open where accounts are added.
    func connect() {
        switch access {
        case .notAsked:
            MeetingCalendar.requestAccessIfNeeded { [weak self] in
                self?.refresh()
                UpcomingMeetings.shared.refresh()
            }
        case .refused:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        case .allowed:
            UpcomingMeetings.openInternetAccounts()
        }
    }
}
