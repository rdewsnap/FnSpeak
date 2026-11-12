import AppKit
import SwiftUI

struct MeetingsTab: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject private var upcoming = UpcomingMeetings.shared
    @State private var screenAccess = CGPreflightScreenCaptureAccess()

    private static let retentionChoices = [0, 7, 30, 90, 365]

    var body: some View {
        KitForm {
            KitSection(title: "Calendar") {
                HStack {
                    Label(upcoming.hasCalendarAccess ? "Connected to the calendars on this Mac" : "Not connected",
                          systemImage: upcoming.hasCalendarAccess ? "checkmark.circle.fill" : "calendar.badge.exclamationmark")
                        .foregroundStyle(upcoming.hasCalendarAccess ? Color.green : Color.orange)
                    Spacer()
                    if !upcoming.hasCalendarAccess {
                        Button("Connect Calendar") { upcoming.connectCalendar() }
                    }
                }
                Text("FnSpeak reads the calendars in the macOS Calendar app, on this Mac only. It uses them to name a meeting, list who's in it, offer to record when a call starts, and show the next meeting with its join link in the menu bar.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("For Google or Outlook calendars, add the account to macOS with Calendars switched on.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Internet Accounts…") { UpcomingMeetings.openInternetAccounts() }
                }
            }

            KitSection(title: "Starting") {
                Toggle("Suggest recording when a call starts", isOn: $prefs.meetingAutoDetect)
                Text("When Zoom, Teams, FaceTime, Slack or a Meet tab looks like a call during a calendar event, FnSpeak sends a notification with a Start button. It never starts recording by itself.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Ask for a title when starting", isOn: $prefs.meetingAskTitle)
                Text("Otherwise the title and participants come from the calendar event happening now, or the date.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            KitSection(title: "Audio") {
                Toggle("Record the other side of the call (system audio)", isOn: $prefs.meetingSystemAudio)
                if prefs.meetingSystemAudio {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: screenAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(screenAccess ? .green : .orange)
                        Text(screenAccess
                             ? "Screen Recording permission is on."
                             : "Needs Screen Recording permission. macOS uses it for app audio too; FnSpeak captures sound only, never your screen.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if !screenAccess {
                            Button("Allow Screen Recording") { MeetingPermissions.requestScreenRecording() }
                        }
                    }
                    Text("Without it, meetings still record your microphone.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Your microphone is recorded with echo cancellation so the call doesn't show up under “Me”. Dictation keeps working during a meeting.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            KitSection(title: "Saving") {
                LabeledContent("Export folder") {
                    HStack {
                        Text(abbreviated(prefs.meetingExportFolder)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                KitPicker("Delete transcripts after", selection: $prefs.meetingRetentionDays) {
                    ForEach(Self.retentionChoices, id: \.self) { days in
                        Text(days == 0 ? "Never" : days == 365 ? "1 year" : "\(days) days").tag(days)
                    }
                }
                Text("No audio is ever stored: only transcripts, summaries and notes, in FnSpeak's data folder. Old meetings are removed at launch.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            KitSection(title: "Summaries") {
                Text("Summaries are written by the cleanup model you chose in Cleanup, and follow the language of the transcript. With Filter only or Raw there's no model, so the transcript is saved with a placeholder summary; switch modes, then use Re-summarize.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { upcoming.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            upcoming.refresh()
            screenAccess = CGPreflightScreenCaptureAccess()
        }
    }

    private func abbreviated(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: prefs.meetingExportFolder, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { prefs.meetingExportFolder = url.path }
    }
}
