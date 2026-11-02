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
    @State private var title = ""
    @State private var editingParticipants = false
    @State private var participantsText = ""
    @FocusState private var titleFocused: Bool

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
        .task(id: meeting.id) {
            title = meeting.title
            loadSegmentsIfNeeded()
        }
        .confirmationDialog("Delete “\(meeting.title)”?", isPresented: $confirmDelete) {
            Button("Delete meeting", role: .destructive) { controller.delete(meeting.id) { _ in } }
        } message: {
            Text("The transcript and summary are removed. Notes you took during it are kept.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onChange(of: titleFocused) { if !titleFocused { commitTitle() } }
                .help("Click to rename")
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                MeetingParticipants(names: meeting.participants)
                Button(meeting.participants.isEmpty ? "Add participants" : "Edit") {
                    participantsText = meeting.participants.joined(separator: ", ")
                    editingParticipants = true
                }
                .buttonStyle(.link)
                .font(.callout)
                .popover(isPresented: $editingParticipants, arrowEdge: .bottom) { participantsEditor }
            }
        }
    }

    private var participantsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Participants").font(.headline)
            TextField("Names, separated by commas", text: $participantsText)
                .frame(width: 280)
                .onSubmit(commitParticipants)
            HStack {
                Spacer()
                Button("Cancel") { editingParticipants = false }
                Button("Save", action: commitParticipants).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
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
                    ForEach(Array(meeting.actionItems.enumerated()), id: \.offset) { index, item in
                        Toggle(isOn: Binding(
                            get: { item.done },
                            set: { setDone($0, at: index) }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.task)
                                    .strikethrough(item.done)
                                    .foregroundStyle(item.done ? .secondary : .primary)
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

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { title = meeting.title; return }
        guard trimmed != meeting.title else { return }
        controller.rename(meeting.id, to: trimmed) { result in apply(result) }
    }

    private func commitParticipants() {
        editingParticipants = false
        let names = participantsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard names != meeting.participants else { return }
        controller.setParticipants(meeting.id, names) { result in apply(result) }
    }

    private func setDone(_ done: Bool, at index: Int) {
        guard meeting.actionItems.indices.contains(index) else { return }
        // Tick right away; the stored meeting comes back a moment later.
        meeting.actionItems[index].done = done
        controller.setActionItem(index, done: done, in: meeting.id) { result in apply(result) }
    }

    /// Take an edited meeting from the core, keeping the segments already loaded.
    private func apply(_ result: Result<Meeting, Error>) {
        switch result {
        case .success(var updated):
            guard updated.id == meeting.id else { return }
            if updated.segments.isEmpty { updated.segments = meeting.segments }
            meeting = updated
            title = updated.title
        case .failure(let error):
            problem = MeetingController.message(for: error)
            title = meeting.title
            loadSegmentsIfNeeded(force: true)
        }
    }

    /// Meetings from the list come without their segments.
    private func loadSegmentsIfNeeded(force: Bool = false) {
        guard force || meeting.segments.isEmpty else { return }
        let id = meeting.id
        controller.meeting(id: id) { full in
            if let full, full.id == meeting.id { meeting = full }
        }
    }
}
