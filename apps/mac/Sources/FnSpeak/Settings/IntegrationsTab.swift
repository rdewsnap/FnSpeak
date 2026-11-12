import AppKit
import EventKit
import SwiftUI

struct IntegrationsTab: View {
    @ObservedObject var prefs = Preferences.shared
    @State private var secret = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var calendarAccess = CalendarNotes.hasAccess

    var body: some View {
        KitForm {
            appleNotes
            markdown
            calendar
            webhook
            shortcuts
        }
        .onAppear {
            secret = prefs.webhookSecret ?? ""
            calendarAccess = CalendarNotes.hasAccess
        }
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
        KitSection(title: "Calendar") {
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
