import AppKit
import Combine
import SwiftUI

/// The Notes window: the list (or search results) on the left, the selected
/// note in an editor on the right.
final class NotesWindowController: NSWindowController, NSWindowDelegate {
    let model = NotesWindowModel()

    init() {
        let host = NSHostingController(rootView: NotesRootView(model: model))
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.title = "Notes"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 560))
        if !window.setFrameUsingName("FlowstateNotes") { window.center() }
        window.setFrameAutosaveName("FlowstateNotes")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Show the window with this search hit selected.
    func show(_ hit: SearchHit) {
        show()
        model.select(hit)
    }

    func windowWillClose(_ notification: Notification) {
        model.flush()
    }
}

final class NotesWindowModel: ObservableObject {
    enum Selection: Hashable {
        case note(Int64)
        case meeting(Int64)
    }

    @Published private(set) var notes: [Note] = []
    @Published var query = "" { didSet { if query != oldValue { searchSoon() } } }
    @Published private(set) var hits: [SearchHit] = []
    @Published var selection: Selection?
    /// Just deleted, for the Undo toast.
    @Published private(set) var deleted: Note?

    /// Saves the open editor's pending changes; set by the editor.
    private var flushEditor: (id: Int64, save: () -> Void)?

    private let store = NotesStore.shared
    private var revisionObserver: AnyCancellable?
    private var searchToken = 0
    private var toastToken = 0

    init() {
        revisionObserver = store.$revision.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var selectedNote: Note? {
        guard case .note(let id) = selection else { return nil }
        return notes.first { $0.id == id }
    }

    func reload() {
        store.notes { [weak self] notes in
            guard let self else { return }
            self.notes = notes
            if self.selection == nil, let first = notes.first { self.selection = .note(first.id) }
            if self.isSearching { self.search() }
        }
    }

    func flush() {
        flushEditor?.save()
    }

    /// The editor for note `id` appeared. When switching notes the new
    /// editor can appear before the old one goes, hence the id.
    func editorAppeared(_ id: Int64, save: @escaping () -> Void) {
        flushEditor = (id, save)
    }

    func editorDisappeared(_ id: Int64) {
        if flushEditor?.id == id { flushEditor = nil }
    }

    func select(_ hit: SearchHit) {
        switch hit.kind {
        case .note:
            if let id = hit.noteId { selection = .note(id) }
        case .meeting, .segment:
            if let id = hit.meetingId { selection = .meeting(id) }
        }
    }

    func newNote() {
        flush()
        query = ""
        store.create(NoteInput(title: "Untitled", bodyMd: "", source: .quick, meetingId: nil, tags: [], pinned: false)) { [weak self] result in
            if case .success(let note) = result { self?.selection = .note(note.id) }
        }
    }

    func togglePin(_ note: Note) {
        flush()
        var input = note.input
        input.pinned.toggle()
        store.update(id: note.id, input)
    }

    func delete(_ note: Note) {
        flush()
        let index = notes.firstIndex { $0.id == note.id }
        store.delete(note) { [weak self] ok in
            guard let self, ok else { return }
            if self.selection == .note(note.id) {
                let rest = self.notes.filter { $0.id != note.id }
                let next = index.flatMap { rest[safe: min($0, rest.count - 1)] }
                self.selection = next.map { .note($0.id) }
            }
            self.showToast(for: note)
        }
    }

    func undoDelete() {
        guard let note = deleted else { return }
        deleted = nil
        store.restore(note) { [weak self] result in
            if case .success(let restored) = result { self?.selection = .note(restored.id) }
        }
    }

    private func showToast(for note: Note) {
        toastToken += 1
        let token = toastToken
        withAnimation(.easeOut(duration: 0.15)) { deleted = note }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.toastToken == token else { return }
            withAnimation(.easeOut(duration: 0.15)) { self.deleted = nil }
        }
    }

    private func searchSoon() {
        searchToken += 1
        let token = searchToken
        guard isSearching else { return hits = [] }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, token == self.searchToken else { return }
            self.search()
        }
    }

    private func search() {
        let token = searchToken
        store.search(query) { [weak self] hits in
            guard let self, token == self.searchToken else { return }
            self.hits = hits
        }
    }
}

extension Note {
    /// The same note as an input, for edits that change one field.
    var input: NoteInput {
        NoteInput(title: title, bodyMd: bodyMd, source: source, meetingId: meetingId, tags: tags, pinned: pinned)
    }
}

private struct NotesRootView: View {
    @ObservedObject var model: NotesWindowModel

    var body: some View {
        NavigationSplitView {
            NotesListView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
        } detail: {
            detail
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: "Search notes and meetings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.newNote() } label: { Label("New Note", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New note (⌘N)")
            }
        }
        .overlay(alignment: .bottom) {
            if let note = model.deleted {
                UndoToast(title: note.title) { model.undoDelete() }
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 680, minHeight: 420)
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .note:
            if let note = model.selectedNote {
                NoteEditorView(note: note, model: model)
                    .id(note.id)
            } else {
                empty
            }
        case .meeting(let id):
            MeetingPreview(meetingId: id).id(id)
        case nil:
            empty
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(model.notes.isEmpty ? "No notes yet" : "Pick a note").foregroundStyle(.secondary)
            if model.notes.isEmpty {
                Text("Press \(Preferences.shared.notesHotkey.displayName) anywhere to jot one down.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct UndoToast: View {
    let title: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Deleted \u{201C}\(title.isEmpty ? "Untitled" : title)\u{201D}").lineLimit(1)
            Button("Undo", action: undo)
                .buttonStyle(.borderless)
                .keyboardShortcut("z", modifiers: .command)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

/// A meeting found by search, shown read-only as Markdown.
private struct MeetingPreview: View {
    let meetingId: Int64
    @State private var markdown: String?
    @State private var failed = false

    var body: some View {
        Group {
            if let markdown {
                ScrollView {
                    MarkdownPreview(text: markdown)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
                .toolbar {
                    ToolbarItem {
                        Button { Pasteboard.copy(markdown) } label: { Label("Copy as Markdown", systemImage: "doc.on.doc") }
                            .help("Copy as Markdown")
                    }
                }
            } else if failed {
                Text("This meeting couldn't be loaded.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            NotesStore.shared.meetingMarkdown(id: meetingId) { text in
                markdown = text
                failed = text == nil
            }
        }
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
