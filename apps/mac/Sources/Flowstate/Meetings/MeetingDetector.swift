import AppKit
import ApplicationServices
import UserNotifications

/// Notices when you seem to be on a call and offers to record it. Every
/// 10 seconds while nothing is recording, it checks for a call app (in
/// front, or running with the mic in use) during a calendar event. It only
/// ever suggests; recording starts when you click Start.
final class MeetingDetector: NSObject {
    private static let category = "dev.flowstate.meeting-suggestion"
    private static let startAction = "start"

    /// Native call apps.
    private static let callApps: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap",
        "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark",
    ]

    /// Browsers whose window titles can show a call (Meet, Teams on the web).
    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox",
    ]

    private static let browserCallTitles = ["Meet - ", "Meet – ", "meet.google.com", "Microsoft Teams", "Zoom Meeting", "Whereby"]

    private weak var controller: MeetingController?
    private let prefs = Preferences.shared
    private var timer: Timer?
    /// Calendar events already suggested, so each is offered once.
    private var suggested: Set<String> = []
    private var notificationsReady = false

    init(controller: MeetingController) {
        self.controller = controller
    }

    func start() {
        guard timer == nil else { return }
        setUpNotifications()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() {
        guard prefs.meetingAutoDetect, let controller, controller.phase == .idle,
              notificationsReady, MeetingCalendar.hasAccess,
              let event = MeetingCalendar.current(), !suggested.contains(event.id),
              let app = callAppInUse() else { return }
        suggested.insert(event.id)
        suggest(event: event, app: app)
    }

    /// The name of the call app in use, if any.
    private func callAppInUse() -> String? {
        let workspace = NSWorkspace.shared
        let front = workspace.frontmostApplication
        if let front, let id = front.bundleIdentifier {
            if Self.callApps.contains(id) { return front.localizedName ?? "a call" }
            if Self.browsers.contains(id), browserShowsCall(front) { return front.localizedName ?? "your browser" }
        }
        // Not in front: only counts when something has the mic open.
        guard MeetingAudio.micInUseSomewhere else { return nil }
        for app in workspace.runningApplications {
            guard let id = app.bundleIdentifier else { continue }
            if Self.callApps.contains(id) { return app.localizedName ?? "a call" }
            if Self.browsers.contains(id), browserShowsCall(app) { return app.localizedName ?? "your browser" }
        }
        return nil
    }

    /// Reads window titles through Accessibility, which Flowstate already has for pasting.
    private func browserShowsCall(_ app: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        for window in windows.prefix(20) {
            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
               let title = title as? String,
               Self.browserCallTitles.contains(where: { title.contains($0) }) {
                return true
            }
        }
        return false
    }

    // MARK: - Notifications

    /// UserNotifications only works from an app bundle (not a bare `swift run`).
    private var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private func setUpNotifications() {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        let start = UNNotificationAction(identifier: Self.startAction, title: "Start recording", options: [])
        let category = UNNotificationCategory(identifier: Self.category, actions: [start], intentIdentifiers: [])
        center.setNotificationCategories([category])
        center.delegate = self
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional: self.notificationsReady = true
                case .notDetermined: self.requestAuthorization()
                default: self.notificationsReady = false
                }
            }
        }
    }

    private func requestAuthorization() {
        guard prefs.meetingAutoDetect else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { self.notificationsReady = granted }
        }
    }

    private func suggest(event: MeetingCalendar.Event, app: String) {
        let content = UNMutableNotificationContent()
        content.title = "In a meeting? Start recording"
        content.body = "“\(event.title)” is on your calendar and \(app) looks like a call. Flowstate can transcribe it and write a summary."
        content.categoryIdentifier = Self.category
        let request = UNNotificationRequest(identifier: "meeting-\(event.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.error("Meeting suggestion failed: \(error.localizedDescription)") }
        }
    }
}

extension MeetingDetector: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            // Clicking the notification itself counts as yes too.
            if category == Self.category, action == Self.startAction || action == UNNotificationDefaultActionIdentifier {
                self.controller?.requestStart()
            }
            completionHandler()
        }
    }
}
