import AppKit
import EventKit
import SwiftUI

struct ConnectorsTab: View {
    @ObservedObject var prefs = Preferences.shared
    @State private var secret = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var calendarAccess = CalendarNotes.hasAccess
    @ObservedObject private var calendars = CalendarAccountList.shared
    /// The calendar card whose Connect was just pressed, to say what to do next.
    @State private var guiding: CalendarAccount.Service?
    @State private var assistantConnected = MCPSetup.isConnected

    var body: some View {
        KitForm {
            connectors
            appleNotes
            markdown
            calendar
            webhook
            shortcuts
        }
        .onAppear {
            secret = prefs.webhookSecret ?? ""
            calendarAccess = CalendarNotes.hasAccess
            assistantConnected = MCPSetup.isConnected
            calendars.start()
        }
        .onChange(of: calendars.accounts) { _, _ in
            calendarAccess = CalendarNotes.hasAccess
            // The account that was being added has arrived.
            if let guiding, !calendars.accounts(for: guiding).isEmpty { self.guiding = nil }
        }
    }

    // MARK: - Connectors

    private var connectors: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            calendarCard(.google, icon: .logo("google-calendar"), name: "Google Calendar",
                         detail: "Reminders and join links for the meetings on your Google calendar.")
            calendarCard(.outlook, icon: .logo("outlook"), name: "Outlook Calendar",
                         detail: "Reminders and join links for Outlook and Microsoft 365 meetings.")
            if !calendars.accounts(for: .other).isEmpty {
                calendarCard(.other, icon: .app("com.apple.iCal"), name: "Apple Calendar",
                             detail: "iCloud and the other calendars already on this Mac.")
            }
            ConnectorCard(icon: .symbol("sparkles"), name: "AI assistants", tags: [],
                          detail: "Let Claude and other MCP clients search your notes and meetings. Runs on this Mac.") {
                if assistantConnected { ConnectedMark() }
                Button(assistantConnected ? "Manage" : "Set up") { SettingsRouter.shared.tab = .notes }
            }
            Text("Calendars are read through macOS, on this Mac. FnSpeak never signs in to Google or Microsoft, and your events aren't sent anywhere.")
                .font(Theme.Fonts.support).foregroundStyle(Theme.textSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
        }
    }

    private func calendarCard(_ service: CalendarAccount.Service, icon: ConnectorIcon, name: String, detail: String) -> some View {
        let accounts = calendars.accounts(for: service)
        let used = accounts.filter { !prefs.calendarIgnoredAccounts.contains($0.id) }
        return ConnectorCard(icon: icon, name: name, tags: accounts.map(\.label), detail: detail,
                             note: note(for: service, connected: !accounts.isEmpty)) {
            if accounts.isEmpty {
                Button("Connect") {
                    guiding = calendars.access == .allowed ? service : nil
                    calendars.connect()
                }
            } else {
                if used.isEmpty { KitTag(text: "Off") } else { ConnectedMark() }
                Menu {
                    ForEach(accounts) { account in
                        let off = prefs.calendarIgnoredAccounts.contains(account.id)
                        Button(off ? "Use \(account.label)" : "Stop using \(account.label)") { setUsed(account, off) }
                    }
                    Divider()
                    Button("Manage in System Settings…") { UpcomingMeetings.openInternetAccounts() }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("\(name) options")
            }
        }
    }

    /// What to do next, under a calendar card that isn't connected yet.
    private func note(for service: CalendarAccount.Service, connected: Bool) -> String? {
        guard !connected else { return nil }
        if calendars.access == .refused {
            return "FnSpeak isn't allowed to read calendars. Connect opens the setting to switch it on."
        }
        guard guiding == service else { return nil }
        let account = service == .google ? "Google" : "Microsoft Exchange"
        return "In System Settings, choose Add Account, then \(account), and leave Calendars switched on. This card updates when it's there."
    }

    private func setUsed(_ account: CalendarAccount, _ used: Bool) {
        var ignored = prefs.calendarIgnoredAccounts.filter { $0 != account.id }
        if !used { ignored.append(account.id) }
        prefs.calendarIgnoredAccounts = ignored
        UpcomingMeetings.shared.refresh()
    }

    // MARK: - Sections

    private var appleNotes: some View {
        KitSection(title: "Apple Notes") {
            TextField("Folder", text: $prefs.appleNotesFolder, prompt: Text("FnSpeak"))
            Text("**Send to Apple Notes** on a note or a meeting copies it into this folder of your default Notes account. The folder is made if it's missing. macOS asks once whether FnSpeak may control Notes.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Automation Settings") { AppleNotes.openAutomationSettings() }
        }
    }

    private var markdown: some View {
        KitSection(title: "Obsidian and Markdown") {
            LabeledContent("Notes") {
                HStack {
                    Text(prefs.notesExportFolder.isEmpty ? "Off" : abbreviated(prefs.notesExportFolder))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Change in Notes") { SettingsRouter.shared.tab = .notes }
                }
            }
            Toggle("Save each meeting as Markdown when it ends", isOn: $prefs.meetingAutoExport)
            LabeledContent("Meetings folder") {
                HStack {
                    Text(abbreviated(prefs.meetingExportFolder)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Same as Notes") { prefs.meetingExportFolder = prefs.notesExportFolder }
                        .disabled(prefs.notesExportFolder.isEmpty || prefs.notesExportFolder == prefs.meetingExportFolder)
                    Button("Choose…", action: chooseMeetingFolder)
                }
            }
            Text("Meetings are written as **date title-meeting-id.md** with front matter (title, date, participants, tags) followed by the summary, action items and transcript.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var calendar: some View {
        KitSection(title: "Calendar events") {
            Toggle("Add a summary to the calendar event when a meeting ends", isOn: $prefs.calendarAppendSummary)
            Text("Only for meetings started during an event. A few lines of the summary and a **fnspeak://** link back to the meeting go at the end of the event's notes. If the calendar syncs, other attendees may see them.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if prefs.calendarAppendSummary && !calendarAccess {
                HStack {
                    Label("Needs full calendar access.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                    Spacer()
                    Button("Allow") {
                        MeetingCalendar.requestAccessIfNeeded { calendarAccess = CalendarNotes.hasAccess }
                        if EKEventStore.authorizationStatus(for: .event) != .notDetermined, !CalendarNotes.hasAccess,
                           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }

    private var webhook: some View {
        KitSection(title: "Webhook") {
            TextField("URL", text: $prefs.webhookURL, prompt: Text("https://example.com/hooks/fnspeak"))
            SecureField("Secret", text: $secret)
                .onSubmit { prefs.webhookSecret = secret }
            ForEach(Webhook.Event.allCases, id: \.rawValue) { event in
                Toggle(event.rawValue, isOn: eventBinding(event))
                    .disabled(Webhook.endpoint == nil)
            }
            HStack {
                Button("Save secret") { prefs.webhookSecret = secret }
                    .disabled(secret == (prefs.webhookSecret ?? ""))
                Button("Send test", action: sendTest).disabled(Webhook.endpoint == nil || testing)
                if testing { ProgressView().controlSize(.small) }
                if let testResult {
                    Label(testResult.message, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(testResult.ok ? Color.green : Color.red).font(.callout)
                }
            }
            Text("Each event is a JSON POST: **event**, **sent_at** and **data** (the note or meeting). With a secret, **X-FnSpeak-Signature** is `sha256=` and the HMAC-SHA256 of the body. Failed posts are retried twice. note.updated is sent once you stop typing.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !prefs.webhookURL.isEmpty && Webhook.endpoint == nil {
                Text("That doesn't look like an http or https URL.").font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private var shortcuts: some View {
        KitSection(title: "Shortcuts and links") {
            Toggle("Let other apps control FnSpeak with fnspeak:// links", isOn: $prefs.urlCommandsEnabled)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Self.links, id: \.0) { link, what in
                    HStack(alignment: .firstTextBaseline) {
                        Text(link).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Text(what).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Text("The Shortcuts app also lists **Start Meeting**, **Stop Meeting**, **Create Note** and **Get Last Dictation** under FnSpeak.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let links: [(String, String)] = [
        ("fnspeak://note?text=…", "Save a note"),
        ("fnspeak://meeting/start?title=…", "Start a meeting"),
        ("fnspeak://meeting/stop", "Stop the meeting"),
        ("fnspeak://dictate", "Start or finish dictating"),
    ]

    // MARK: - Helpers

    private func eventBinding(_ event: Webhook.Event) -> Binding<Bool> {
        Binding(
            get: { !prefs.webhookDisabledEvents.contains(event.rawValue) },
            set: { on in
                var disabled = prefs.webhookDisabledEvents.filter { $0 != event.rawValue }
                if !on { disabled.append(event.rawValue) }
                prefs.webhookDisabledEvents = disabled
            }
        )
    }

    private func sendTest() {
        prefs.webhookSecret = secret
        testing = true
        testResult = nil
        Webhook.send("ping", data: ["message": "Test from FnSpeak settings"]) { status, error in
            testing = false
            if let status {
                testResult = ((200..<300).contains(status), "HTTP \(status)")
            } else {
                testResult = (false, error?.localizedDescription ?? "No answer")
            }
        }
    }

    private func abbreviated(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func chooseMeetingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: prefs.meetingExportFolder, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { prefs.meetingExportFolder = url.path }
    }
}

/// One thing FnSpeak can be connected to: what it is, what it's for, and
/// on the right either the way to connect it or the sign that it is.
struct ConnectorCard<Trailing: View>: View {
    let icon: ConnectorIcon
    let name: String
    /// The accounts connected, shown beside the name.
    let tags: [String]
    let detail: String
    var note: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                icon
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.s) {
                        Text(name).font(Theme.Fonts.heading).foregroundStyle(Theme.text)
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(Theme.Fonts.caption).foregroundStyle(Theme.textSoft)
                                .lineLimit(1).truncationMode(.middle)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.sunk))
                        }
                    }
                    Text(detail).font(Theme.Fonts.support).foregroundStyle(Theme.textSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note {
                        Label(note, systemImage: "info.circle")
                            .font(Theme.Fonts.support).foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: Theme.Space.m)
                HStack(spacing: Theme.Space.s) { trailing }
            }
        }
    }
}

/// The tick on a connector that's working.
struct ConnectedMark: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Theme.good)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Theme.good.opacity(0.12)))
            .overlay(Circle().strokeBorder(Theme.good.opacity(0.5), lineWidth: 1))
            .accessibilityLabel("Connected")
    }
}

/// What stands for a connector: the service's own logo, an app's icon, or
/// a plain symbol when it isn't one company's product.
enum ConnectorIcon: View {
    /// A logo bundled with the app, by file name. Logos are kept exactly as
    /// their owners publish them, on an opaque white plate, so they look the
    /// same in light and dark.
    case logo(String)
    /// The icon of an app on this Mac, by bundle id.
    case app(String)
    case symbol(String)

    private static let side: CGFloat = 32
    private static var cache: [String: NSImage] = [:]

    private static func bundled(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        switch self {
        case .logo(let name):
            if let image = Self.bundled(name) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Theme.line, lineWidth: 1))
                    .accessibilityHidden(true)
            } else {
                // A build without the app bundle, such as `swift build` alone.
                ConnectorIcon.symbol("calendar")
            }
        case .app(let bundleId):
            if let image = AppIcons.icon(bundleId) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: Self.side, height: Self.side)
                    .accessibilityHidden(true)
            } else {
                ConnectorIcon.symbol("calendar")
            }
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)
                .frame(width: Self.side, height: Self.side)
                .background(shape.fill(Theme.sunk))
                .accessibilityHidden(true)
        }
    }
}
