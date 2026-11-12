import SwiftUI

/// The sidebar: every note (pinned first, then recent), or search hits across
/// notes, meetings and transcripts while there's a query.
struct NotesListView: View {
    @ObservedObject var model: NotesWindowModel

    var body: some View {
        List(selection: $model.selection) {
            if model.isSearching {
                searchResults
            } else {
                allNotes
            }
        }
        .listStyle(.sidebar)
        // The split view backs this column with the system's see-through
        // sidebar material. Cover it, so the column is the kit's page colour.
        .scrollContentBackground(.hidden)
        .background(Theme.page.ignoresSafeArea())
        .onDeleteCommand {
            if let note = model.selectedNote { model.delete(note) }
        }
    }

    @ViewBuilder private var allNotes: some View {
        let pinned = model.notes.filter(\.pinned)
        let rest = model.notes.filter { !$0.pinned }
        if !pinned.isEmpty {
            Section("Pinned") {
                ForEach(pinned, id: \.id) { row($0) }
            }
        }
        Section(pinned.isEmpty ? "Notes" : "Recent") {
            ForEach(rest, id: \.id) { row($0) }
        }
    }

    private func row(_ note: Note) -> some View {
        NoteRow(note: note)
            .tag(NotesWindowModel.Selection.note(note.id))
            .contextMenu {
                Button(note.pinned ? "Unpin" : "Pin") { model.togglePin(note) }
                Button("Copy as Markdown") { Pasteboard.copy(note.markdown) }
                Divider()
                Button("Delete", role: .destructive) { model.delete(note) }
            }
    }

    @ViewBuilder private var searchResults: some View {
        if model.hits.isEmpty {
            Text("No matches").foregroundStyle(.secondary)
        }
        ForEach(Array(model.hits.enumerated()), id: \.offset) { _, hit in
            if let selection = hit.selection {
                HitRow(hit: hit)
                    .padding(.vertical, 2)
                    .tag(selection)
            }
        }
    }
}

private extension SearchHit {
    var selection: NotesWindowModel.Selection? {
        switch kind {
        case .note: return noteId.map { .note($0) }
        case .meeting, .segment: return meetingId.map { .meeting($0) }
        }
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if note.pinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                }
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            Text(preview)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(Date(timeIntervalSince1970: TimeInterval(note.updatedAt)), format: .relative(presentation: .named))
                if !note.tags.isEmpty {
                    Text(note.tags.map { "#\($0)" }.joined(separator: " ")).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }

    /// The body without the title line, on one line.
    private var preview: String {
        var lines = note.bodyMd.split(whereSeparator: \.isNewline).map(String.init)
        if let first = lines.first, NoteText.firstLineTitle(first) == note.title { lines.removeFirst() }
        let text = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "No additional text" : text
    }
}
