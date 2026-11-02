import AppKit
import SwiftUI

/// A finished meeting: summary, action items, transcript, and what you can do with them.
struct MeetingDetailView: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var prefs = Preferences.shared
    @State var meeting: Meeting
    @State private var resummarizing = false
    @State private var confirmDelete = false
    @State private var copied: String?
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let problem {
                        MeetingBanner(text: problem, onDismiss: { self.problem = nil })
                    }
                    summary
                    actionItems
                    transcript
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actions.padding(12)
        }
        .task(id: meeting.id) { loadSegmentsIfNeeded() }
        .confirmationDialog("Delete “\(meeting.title)”?", isPresented: $confirmDelete) {
            Button("Delete meeting", role: .destructive) { controller.delete(meeting.id) { _ in } }
        } message: {
            Text("The transcript and summary are removed. Notes you took during it are kept.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            MeetingParticipants(names: meeting.participants)
        }
    }

    private var subtitle: String {
        let start = Date(timeIntervalSince1970: TimeInterval(meeting.startedAt))
        var parts = [start.formatted(date: .complete, time: .shortened)]
        if let end = meeting.endedAt {
            let minutes = max(1, Int((end - meeting.startedAt + 30) / 60))
            parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var summary: some View {
        if let md = meeting.summaryMd, !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            GroupBox {
                MeetingMarkdown(markdown: md, skippingSections: meeting.actionItems.isEmpty ? [] : ["action item"])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            } label: {
                Label("Summary", systemImage: "text.alignleft")
            }
        } else {
            MeetingBanner(
                text: meeting.status == .processing
                    ? "No summary yet. The transcript is saved; try summarizing again."
                    : "This meeting has no summary.",
                systemImage: "info.circle", tint: .blue,
                action: ("Summarize", resummarize)
            )
        }
    }

    @ViewBuilder
    private var actionItems: some View {
        if !meeting.actionItems.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(meeting.actionItems.enumerated()), id: \.offset) { _, item in
                        Toggle(isOn: Binding(
                            get: { controller.isDone(item, in: meeting) },
                            set: { controller.setDone($0, item, in: meeting) }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.task)
                                    .strikethrough(controller.isDone(item, in: meeting))
                                    .foregroundStyle(controller.isDone(item, in: meeting) ? .secondary : .primary)
                                let detail = [item.owner, item.due.map { "due \($0)" }].compactMap { $0 }
                                if !detail.isEmpty {
                                    Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: {
                Label("Action items", systemImage: "checklist")
            }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        GroupBox {
            if meeting.segments.isEmpty {
                if let md = meeting.transcriptMd, !md.isEmpty {
                    Text(md).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                } else {
                    Text("Nothing was transcribed.").foregroundStyle(.secondary).padding(6)
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(meeting.segments, id: \.id) { MeetingSegmentRow(segment: $0) }
                }
                .padding(6)
            }
        } label: {
            Label("Transcript", systemImage: "text.quote")
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Copy summary") { copy(meeting.summaryMd ?? "", label: "Summary") }
                .disabled((meeting.summaryMd ?? "").isEmpty)
            Button("Copy transcript") { copy(MeetingController.transcriptText(meeting), label: "Transcript") }
            Button("Export Markdown…") { controller.export(meeting) }
            if let copied {
                Text("\(copied) copied").font(.callout).foregroundStyle(.secondary).transition(.opacity)
            }
            Spacer()
            if resummarizing {
                ProgressView().controlSize(.small)
            }
            Button("Re-summarize", action: resummarize).disabled(resummarizing)
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .help("Delete this meeting")
        }
    }

    // MARK: - Actions

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copied = label }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { if copied == label { copied = nil } } }
    }

    private func resummarize() {
        resummarizing = true
        problem = nil
        controller.resummarize(meeting.id) { result in
            resummarizing = false
            switch result {
            case .success(let updated): meeting = updated
            case .failure(let error): problem = MeetingController.message(for: error)
            }
        }
    }

    /// Meetings from the list come without their segments.
    private func loadSegmentsIfNeeded() {
        guard meeting.segments.isEmpty else { return }
        let id = meeting.id
        controller.meeting(id: id) { full in
            if let full, full.id == meeting.id { meeting = full }
        }
    }
}
