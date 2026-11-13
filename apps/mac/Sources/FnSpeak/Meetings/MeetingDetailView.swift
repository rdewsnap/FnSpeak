import AppKit
import SwiftUI

/// A finished meeting: summary, action items, transcript, and what you can do with them.
struct MeetingDetailView: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var downloader = ModelDownloader.shared
    @State var meeting: Meeting
    @State private var resummarizing = false
    @State private var confirmDelete = false
    @State private var copied: String?
    @State private var problem: String?
    @State private var title = ""
    /// The meeting's pad, as it's being edited here.
    @State private var notes = ""
    /// What the pad said when the summary on screen was written.
    @State private var summarizedNotes = ""
    @State private var notesSave: DispatchWorkItem?
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
                    myNotes
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
            notes = meeting.notesMd ?? ""
            summarizedNotes = notes
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
        // Reading `revision` re-checks the disk once the model has landed.
        if meeting.writtenSummary == nil, downloader.revision >= 0, ModelLocator.summaryNeedsModel {
            MeetingSummaryModelNotice()
        } else if let md = meeting.writtenSummary {
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

    /// The meeting's pad. It can be added to after the meeting, and the
    /// summary rewritten to take the changes in.
    private var myNotes: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $notes)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 70)
                    if notes.isEmpty {
                        Text("Add what you want remembered from this meeting. It's used when the summary is written.")
                            .foregroundStyle(.tertiary)
                            // Where the editor puts its first character.
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                if notes.trimmingCharacters(in: .whitespacesAndNewlines) != summarizedNotes.trimmingCharacters(in: .whitespacesAndNewlines) {
                    HStack(spacing: 8) {
                        Button("Update summary", action: resummarize).disabled(resummarizing)
                        Text("Rewrites the summary with your notes.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("My notes", systemImage: "pencil.line")
        }
        .onChange(of: notes) { _, text in
            guard text != (meeting.notesMd ?? "") else { return }
            notesSave?.cancel()
            let id = meeting.id
            let save = DispatchWorkItem { controller.saveNotes(id, text) }
            notesSave = save
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: save)
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
            Button("Send to Apple Notes") {
                problem = nil
                controller.sendToAppleNotes(meeting) { result in
                    switch result {
                    case .success: flash("Sent to Notes")
                    case .failure(let error): problem = MeetingController.message(for: error)
                    }
                }
            }
            .help("Copy the summary and action items into Apple Notes")
            ShareWithTeamMenu(kind: .meeting, localId: meeting.id).fixedSize()
            if let copied {
                Text(copied).font(.callout).foregroundStyle(.secondary).transition(.opacity)
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
        flash("\(label) copied")
    }

    private func flash(_ message: String) {
        withAnimation { copied = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { if copied == message { copied = nil } } }
    }

    private func resummarize() {
        resummarizing = true
        problem = nil
        // The pad has to be saved before the summary reads it.
        notesSave?.cancel()
        let used = notes
        controller.saveNotes(meeting.id, used) {
            controller.resummarize(meeting.id) { result in
                resummarizing = false
                switch result {
                case .success(let updated):
                    meeting = updated
                    summarizedNotes = used
                case .failure(let error):
                    problem = MeetingController.message(for: error)
                }
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
