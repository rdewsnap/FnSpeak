import AppKit
import SwiftUI

/// Past meetings: a sidebar by date with search, and the summary on the right.
final class MeetingsListWindowController: NSWindowController {
    init(controller: MeetingController) {
        let host = NSHostingController(rootView: MeetingsListView(controller: controller))
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.title = "Meetings"
        window.setContentSize(NSSize(width: 900, height: 620))
        if !window.setFrameUsingName("FnSpeakMeetings") { window.center() }
        window.setFrameAutosaveName("FnSpeakMeetings")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MeetingsListView: View {
    @ObservedObject var controller: MeetingController
    @State private var meetings: [Meeting] = []
    @State private var selection: Int64?
    @State private var query = ""
    /// Meeting id → matching snippet, while searching.
    @State private var matches: [Int64: String]?
    @State private var matchOrder: [Int64] = []
    @State private var loaded = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .safeAreaInset(edge: .top, spacing: 0) {
                    KitField(prompt: "Search meetings", text: $query, symbol: "magnifyingglass")
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.s)
                        .background(Theme.page)
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
        } detail: {
            if let meeting = meetings.first(where: { $0.id == selection }) {
                MeetingDetailView(controller: controller, meeting: meeting).id(meeting.id)
            } else {
                Text(meetings.isEmpty && loaded ? "No meetings yet" : "Select a meeting")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar(removing: .sidebarToggle)
        // No navigation title: it would be drawn in the window's top bar,
        // beside the close buttons. The window sets its own name.
        .task(id: controller.revision) { reload() }
        .task(id: query) { await runSearch() }
        .onChange(of: controller.focusMeetingId) { takeFocus() }
        .kitHeader("Meetings") {
            Button {
                controller.requestStart()
            } label: {
                Label(controller.isRecording ? "Show meeting" : "Start meeting", systemImage: "record.circle")
            }
            .buttonStyle(.kitPrimary)
            .help(controller.isRecording ? "Show the meeting being recorded" : "Start recording a meeting")
        }
        .frame(minWidth: 620, minHeight: 440)
        .tint(Theme.accent)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            if let matches {
                if matchOrder.isEmpty {
                    Text("No matches").foregroundStyle(.secondary)
                }
                ForEach(matchOrder.compactMap { id in meetings.first { $0.id == id } }, id: \.id) { meeting in
                    MeetingListRow(meeting: meeting, snippet: matches[meeting.id]).tag(meeting.id)
                }
            } else {
                ForEach(groups, id: \.day) { group in
                    Section(group.title) {
                        ForEach(group.meetings, id: \.id) { MeetingListRow(meeting: $0, snippet: nil).tag($0.id) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // The split view backs this column with the system's see-through
        // sidebar material. Cover it, so the column is the kit's page colour.
        .scrollContentBackground(.hidden)
        .background(Theme.page.ignoresSafeArea())
    }

    private struct DayGroup { let day: Date; let title: String; let meetings: [Meeting] }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: meetings) {
            calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.startedAt)))
        }
        return byDay.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) { title = "Today" }
            else if calendar.isDateInYesterday(day) { title = "Yesterday" }
            else { title = day.formatted(date: .complete, time: .omitted) }
            return DayGroup(day: day, title: title, meetings: byDay[day]!.sorted { $0.startedAt > $1.startedAt })
        }
    }

    private func reload() {
        controller.meetings { list in
            meetings = list
            loaded = true
            if let selection, !list.contains(where: { $0.id == selection }) { self.selection = nil }
            takeFocus()
        }
    }

    /// Select the meeting the dock handed over.
    private func takeFocus() {
        guard let id = controller.focusMeetingId, meetings.contains(where: { $0.id == id }) else { return }
        query = ""
        selection = id
        controller.focusMeetingId = nil
    }

    private func runSearch() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            matches = nil
            matchOrder = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        controller.search(text) { hits in
            guard text == query.trimmingCharacters(in: .whitespaces) else { return }
            var order: [Int64] = []
            var snippets: [Int64: String] = [:]
            for hit in hits {
                guard let id = hit.meetingId, hit.kind != .note else { continue }
                if snippets[id] == nil {
                    order.append(id)
                    let at = hit.startedMs.map { "[\(MeetingController.timestamp(ms: $0))] " } ?? ""
                    snippets[id] = at + hit.snippet
                }
            }
            matchOrder = order
            matches = snippets
        }
    }
}

private struct MeetingListRow: View {
    let meeting: Meeting
    let snippet: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if meeting.status == .recording {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                }
                Text(meeting.title).lineLimit(1)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let snippet {
                Text(MeetingMarkdown.inline(snippet)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        let start = Date(timeIntervalSince1970: TimeInterval(meeting.startedAt))
        var parts = [start.formatted(date: snippet == nil ? .omitted : .abbreviated, time: .shortened)]
        if let end = meeting.endedAt { parts.append("\(max(1, Int((end - meeting.startedAt + 30) / 60))) min") }
        switch meeting.status {
        case .recording: parts.append("recording")
        case .processing: parts.append("no summary")
        case .done: if !meeting.actionItems.isEmpty { parts.append("\(meeting.actionItems.count) action items") }
        }
        return parts.joined(separator: " · ")
    }
}
