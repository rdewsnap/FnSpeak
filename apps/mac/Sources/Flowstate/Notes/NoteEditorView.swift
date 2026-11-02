import AppKit
import SwiftUI

/// One note: title, tags, and the Markdown body as plain text, with a
/// rendered preview. Edits save on their own a moment after you stop typing.
struct NoteEditorView: View {
    let note: Note
    @ObservedObject var model: NotesWindowModel

    @State private var title: String
    @State private var bodyText: String
    @State private var tagsText: String
    @State private var dirty = false
    @State private var saveToken = 0
    @AppStorage("notesPreview") private var preview = false

    private let store = NotesStore.shared

    init(note: Note, model: NotesWindowModel) {
        self.note = note
        self.model = model
        _title = State(initialValue: note.title)
        _bodyText = State(initialValue: note.bodyMd)
        _tagsText = State(initialValue: Self.tagsString(note.tags))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title (leave empty to have one written)", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 16)

            HStack(spacing: 6) {
                Image(systemName: "number").foregroundStyle(.tertiary)
                TextField("Add tags", text: $tagsText)
                    .textFieldStyle(.plain)
                Spacer()
                Text(meta).foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            Divider()

            if preview {
                ScrollView {
                    MarkdownPreview(text: bodyText, onToggleTask: toggleTask)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                }
            } else {
                TextEditor(text: $bodyText)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar { toolbar }
        .onChange(of: title) { changed() }
        .onChange(of: bodyText) { changed() }
        .onChange(of: tagsText) { changed() }
        .onChange(of: note.updatedAt) { refreshFromStore() }
        .onAppear { model.flushEditor = { saveNow() } }
        .onDisappear {
            saveNow()
            model.flushEditor = nil
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Toggle(isOn: $preview) { Label("Preview", systemImage: preview ? "eye.fill" : "eye") }
                .help(preview ? "Edit Markdown" : "Show preview")
            Button { model.togglePin(note) } label: {
                Label(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin")
            }
            .help(note.pinned ? "Unpin" : "Pin to the top")
            Button { saveNow(); Pasteboard.copy(currentNote.markdown) } label: {
                Label("Copy as Markdown", systemImage: "doc.on.doc")
            }
            .help("Copy as Markdown")
            if NoteExporter.folder != nil {
                Button { revealInFinder() } label: { Label("Reveal in Finder", systemImage: "folder") }
                    .help("Show the exported Markdown file in Finder")
            }
            Button(role: .destructive) { model.delete(note) } label: { Label("Delete", systemImage: "trash") }
                .help("Delete note")
        }
    }

    private var meta: String {
        let created = Date(timeIntervalSince1970: TimeInterval(note.createdAt))
        let source: String
        switch note.source {
        case .quick: source = "Quick note"
        case .dictation: source = "From dictation"
        case .meeting: source = "From a meeting"
        }
        return "\(source) · \(created.formatted(date: .abbreviated, time: .shortened))"
    }

    /// What's on screen, as a note.
    private var currentNote: Note {
        var copy = note
        copy.title = title
        copy.bodyMd = bodyText
        copy.tags = tags
        return copy
    }

    /// Tags typed in the field plus `#tags` in the body.
    private var tags: [String] {
        var result: [String] = []
        let typed = tagsText.split { $0 == "," || $0.isWhitespace }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased() }
        for tag in typed + NoteText.tags(in: bodyText) where !tag.isEmpty && !result.contains(tag) {
            result.append(tag)
        }
        return result
    }

    private static func tagsString(_ tags: [String]) -> String {
        tags.joined(separator: ", ")
    }

    private func changed() {
        guard title != note.title || bodyText != note.bodyMd || tagsText != Self.tagsString(note.tags) else { return }
        dirty = true
        saveToken += 1
        let token = saveToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if token == saveToken { saveNow() }
        }
    }

    private func saveNow() {
        guard dirty else { return }
        dirty = false
        let input = NoteInput(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            bodyMd: bodyText,
            source: note.source,
            meetingId: note.meetingId,
            tags: tags,
            pinned: note.pinned
        )
        store.update(id: note.id, input)
    }

    /// The stored note changed (a save landed, or a title was written for
    /// it); show that unless there are edits on the way.
    private func refreshFromStore() {
        guard !dirty else { return }
        if title != note.title { title = note.title }
        if bodyText != note.bodyMd { bodyText = note.bodyMd }
        let stored = Self.tagsString(note.tags)
        if Set(tags) != Set(note.tags) { tagsText = stored }
    }

    private func revealInFinder() {
        saveNow()
        store.export(currentNote) { url in
            guard let url else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func toggleTask(line: Int) {
        var lines = bodyText.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return }
        if let r = lines[line].range(of: "- [ ] ") {
            lines[line].replaceSubrange(r, with: "- [x] ")
        } else if let r = lines[line].range(of: "- [x] ") ?? lines[line].range(of: "- [X] ") {
            lines[line].replaceSubrange(r, with: "- [ ] ")
        }
        bodyText = lines.joined(separator: "\n")
    }
}

/// A light Markdown renderer: headings, tasks, lists, quotes and code blocks
/// line by line, inline styles through `AttributedString(markdown:)`.
struct MarkdownPreview: View {
    let text: String
    var onToggleTask: ((Int) -> Void)?

    private enum Block {
        case heading(Int, String)
        case task(Bool, String, line: Int, indent: Int)
        case bullet(String, indent: Int)
        case numbered(String, String, indent: Int)
        case quote(String)
        case code(String)
        case paragraph(String)
        case blank
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .font(.system(size: 14))
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: level == 1 ? 22 : level == 2 ? 18 : 15, weight: .semibold))
                .padding(.top, level == 1 ? 6 : 4)
        case .task(let done, let text, let line, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button { onToggleTask?(line) } label: {
                    Image(systemName: done ? "checkmark.square.fill" : "square")
                        .foregroundStyle(done ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(onToggleTask == nil)
                Text(inline(text))
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? .secondary : .primary)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .bullet(let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let number, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number).foregroundStyle(.secondary).monospacedDigit()
                Text(inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                Text(inline(text)).foregroundStyle(.secondary)
            }
        case .code(let text):
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        case .paragraph(let text):
            Text(inline(text))
        case .blank:
            Spacer().frame(height: 4)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        NoteText.highlighted(text)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var code: [String]?
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let lines = code {
                    result.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                result.append(.blank)
            } else if let level = Self.headingLevel(line) {
                result.append(.heading(level, String(line.dropFirst(level + 1))))
            } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                result.append(.task(!line.hasPrefix("- [ ] "), String(line.dropFirst(6)), line: index, indent: indent))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                result.append(.bullet(String(line.dropFirst(2)), indent: indent))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                result.append(.numbered(String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...]), indent: indent))
            } else if line.hasPrefix(">") {
                result.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                result.append(.paragraph(line))
            }
        }
        if let lines = code { result.append(.code(lines.joined(separator: "\n"))) }
        return result
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return hashes
    }
}
