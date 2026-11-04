import AppKit
import SwiftUI

/// A floating one-line field for capturing a thought without switching apps.
///
/// It's a non-activating panel: it takes keyboard focus but the app you were
/// in stays frontmost, so closing it drops you back where you were. Holding
/// the dictation hotkey while it's open dictates into it; so does the mic
/// button. Return saves, Shift-Return adds a line, Esc closes. Text starting
/// with `/` or `?` searches instead.
final class NotesBar: NSObject, NSWindowDelegate {
    /// Start or stop a dictation, as the hotkey would.
    var toggleMic: (() -> Void)?
    /// Whether a dictation is recording right now.
    var isListening: (() -> Bool)?
    /// A search hit was chosen.
    var onOpenHit: ((SearchHit) -> Void)?

    private let model = NotesBarModel()
    private let prefs = Preferences.shared
    private let store = NotesStore.shared
    private weak var textView: NSTextView?
    private var listenTimer: Timer?
    private var searchToken = 0
    private var anchorBottom = true

    static let width: CGFloat = 520

    private lazy var panel: NotesPanel = {
        let panel = NotesPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 64),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        panel.delegate = self

        let view = NotesBarView(
            model: model,
            onReady: { [weak self] text in
                // The field is created after the first show() asked for focus.
                self?.textView = text
                if self?.panel.isVisible == true { self?.panel.makeFirstResponder(text) }
            },
            onSubmit: { [weak self] in self?.submit() },
            onCancel: { [weak self] in self?.hide() },
            onMove: { [weak self] in self?.moveSelection($0) ?? false },
            onMic: { [weak self] in self?.micTapped() },
            onOpen: { [weak self] in self?.open($0) },
            onTextChange: { [weak self] in self?.textChanged($0) },
            onSize: { [weak self] in self?.resize(to: $0) }
        )
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }()

    var isVisible: Bool { panel.isVisible }

    /// The bar is open and its field has focus, so a dictation should land here.
    var wantsDictation: Bool { panel.isVisible && panel.isKeyWindow && model.state != .saved }

    // MARK: - Showing

    func toggle() {
        panel.isVisible && panel.isKeyWindow ? hide() : show()
    }

    func show() {
        if model.state != .editing { model.state = .editing }
        let wasVisible = panel.isVisible
        let target = frame(for: panel.frame.height)
        if wasVisible {
            panel.setFrame(target, display: true)
        } else {
            // Slide out from where the pill sits.
            var start = target
            start.origin.y += anchorBottom ? -10 : 10
            panel.setFrame(start, display: false)
            panel.alphaValue = 0
        }
        panel.makeKeyAndOrderFront(nil)
        if let textView { panel.makeFirstResponder(textView) }
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }
        startWatchingMic()
    }

    func hide() {
        listenTimer?.invalidate()
        listenTimer = nil
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
            if self?.model.state == .saved { self?.reset() }
        })
    }

    /// Put dictated text at the cursor. Returns false if the bar isn't taking dictation.
    @discardableResult
    func insertDictation(_ text: String) -> Bool {
        guard wantsDictation, let textView else { return false }
        let range = textView.selectedRange()
        let before = (textView.string as NSString).substring(to: range.location)
        let needsSpace = !(before.isEmpty || before.last?.isWhitespace == true)
        textView.insertText((needsSpace ? " " : "") + text, replacementRange: range)
        return true
    }

    // MARK: - Actions

    private func submit() {
        if model.query != nil {
            if let hit = model.hits[safe: model.selected] { open(hit) }
            return
        }
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, model.state == .editing else { return }
        guard store.isReady else {
            model.error = "FnSpeak is still starting up. Try again in a moment."
            return
        }
        model.state = .saving
        // Save with the first line as title so it's instant, then let the
        // cleanup model write a better one in the background.
        let autoTitle = prefs.notesAutoTitle
        var input = NoteText.input(from: text, source: .quick, autoTitle: false)
        let quickTitle = input.title
        store.create(input) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let note):
                self.model.state = .saved
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    if self?.model.state == .saved { self?.hide() }
                }
                if autoTitle {
                    input.title = ""
                    self.store.update(id: note.id, input) { result in
                        if case .failure = result { Log.info("Kept the first-line title \"\(quickTitle)\"") }
                    }
                }
            case .failure(let error):
                self.model.state = .editing
                self.model.error = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }

    private func reset() {
        model.text = ""
        model.hits = []
        model.selected = 0
        model.error = nil
        model.state = .editing
        textView?.string = ""
    }

    private func micTapped() {
        toggleMic?()
        model.listening = isListening?() ?? false
    }

    private func open(_ hit: SearchHit) {
        reset()
        hide()
        onOpenHit?(hit)
    }

    private func moveSelection(_ delta: Int) -> Bool {
        guard model.query != nil, !model.hits.isEmpty else { return false }
        model.selected = (model.selected + delta + model.hits.count) % model.hits.count
        return true
    }

    private func textChanged(_ text: String) {
        model.text = text
        model.error = nil
        guard let query = model.query else {
            if !model.hits.isEmpty { model.hits = [] }
            return
        }
        searchToken += 1
        let token = searchToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, token == self.searchToken else { return }
            self.store.search(query) { [weak self] hits in
                guard let self, token == self.searchToken else { return }
                self.model.hits = Array(hits.prefix(5))
                self.model.selected = 0
            }
        }
    }

    private func startWatchingMic() {
        listenTimer?.invalidate()
        model.listening = isListening?() ?? false
        listenTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = self.isListening?() ?? false
            if now != self.model.listening { self.model.listening = now }
        }
    }

    // MARK: - Layout

    private func resize(to height: CGFloat) {
        guard abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        if !anchorBottom { frame.origin.y += frame.height - height }
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    /// Where the bar opens, per the notes setting; "pill" follows the pill's position.
    private func frame(for height: CGFloat) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = Self.width
        var origin = NSPoint(x: visible.midX - width / 2, y: 0)

        var position = prefs.notesBarPosition
        if position == "pill" {
            switch prefs.overlayPosition {
            case "top": position = "pillTop"
            case "cursor": position = "cursor"
            default: position = "pillBottom"
            }
        }
        switch position {
        case "center":
            anchorBottom = false
            origin.y = visible.midY + visible.height * 0.12 - height
        case "top", "pillTop":
            anchorBottom = false
            origin.y = visible.maxY - height - (position == "top" ? visible.height * 0.18 : 64)
        case "cursor":
            anchorBottom = false
            origin = NSPoint(x: mouse.x - width / 2, y: mouse.y - height - 12)
        default:
            anchorBottom = true
            origin.y = visible.minY + 64
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - height - 8)
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Clicked away from an empty bar: put it away. With text in it, leave
        // it up so nothing is lost.
        if model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.state == .editing {
            hide()
        }
    }
}

/// Borderless panels can't become key unless they say so; this one needs to
/// so its field takes typing, while `.nonactivatingPanel` keeps the other app
/// frontmost.
final class NotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class NotesBarModel: ObservableObject {
    enum State: Equatable { case editing, saving, saved }

    @Published var text = ""
    @Published var state = State.editing
    @Published var error: String?
    @Published var listening = false
    @Published var hits: [SearchHit] = []
    @Published var selected = 0

    /// The search query when the text starts with `/` or `?`.
    var query: String? {
        guard let first = text.first, first == "/" || first == "?" else { return nil }
        return String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
}

private struct NotesBarView: View {
    @ObservedObject var model: NotesBarModel
    let onReady: (NSTextView) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onMove: (Int) -> Bool
    let onMic: () -> Void
    let onOpen: (SearchHit) -> Void
    let onTextChange: (String) -> Void
    let onSize: (CGFloat) -> Void

    @State private var fieldHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.query == nil ? "square.and.pencil" : "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 22)
                ZStack(alignment: .topLeading) {
                    if model.text.isEmpty {
                        Text("Jot a note, or / to search")
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 1)
                            .allowsHitTesting(false)
                    }
                    BarTextView(
                        height: $fieldHeight,
                        onReady: onReady, onSubmit: onSubmit, onCancel: onCancel,
                        onMove: onMove, onTextChange: onTextChange
                    )
                    .frame(height: fieldHeight)
                }
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if model.query != nil {
                hitList
            }

            footer
        }
        .frame(width: NotesBar.width)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { onSize(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, height in onSize(height) }
        })
        .animation(.easeOut(duration: 0.15), value: model.state)
        .animation(.easeOut(duration: 0.15), value: model.hits.count)
    }

    @ViewBuilder private var trailing: some View {
        switch model.state {
        case .saving:
            ProgressView().controlSize(.small).frame(width: 26, height: 22)
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
                .frame(height: 22)
                .transition(.opacity)
        case .editing:
            Button(action: onMic) {
                Image(systemName: model.listening ? "stop.circle.fill" : "mic")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(model.listening ? Color.red : Color.secondary)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.listening ? "Stop and insert" : "Dictate")
        }
    }

    private var hitList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.hits.isEmpty {
                Text(model.query?.isEmpty == false ? "No matches" : "Type to search notes and meetings")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            ForEach(Array(model.hits.enumerated()), id: \.offset) { index, hit in
                Button { onOpen(hit) } label: {
                    HitRow(hit: hit)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(index == model.selected ? Color.accentColor.opacity(0.22) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .transition(.opacity)
    }

    private var footer: some View {
        HStack {
            if let error = model.error {
                Text(error).foregroundStyle(.orange)
            } else if model.listening {
                Text("Listening… click stop or let go of the hotkey").foregroundStyle(.red.opacity(0.85))
            } else {
                Text(model.query == nil ? "⏎ save · ⇧⏎ newline · esc close" : "↑↓ choose · ⏎ open · esc close")
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.bottom, 9)
    }
}

/// One search hit: title, kind, and the snippet with matches in bold.
struct HitRow: View {
    let hit: SearchHit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: hit.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.title.isEmpty ? "Untitled" : hit.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(NoteText.highlighted(hit.snippet))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

extension SearchHit {
    var symbol: String {
        switch kind {
        case .note: return "note.text"
        case .meeting: return "person.2"
        case .segment: return "quote.bubble"
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The bar's field: an NSTextView, because it needs Return vs Shift-Return,
/// arrow keys for search hits, inserting dictation at the cursor, and growing
/// line by line, none of which a SwiftUI field does on its own.
private struct BarTextView: NSViewRepresentable {
    @Binding var height: CGFloat
    let onReady: (NSTextView) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onMove: (Int) -> Bool
    let onTextChange: (String) -> Void

    static let maxHeight: CGFloat = 180

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: NSViewRepresentableContext<BarTextView>) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.delegate = context.coordinator
        text.font = .systemFont(ofSize: 15)
        text.textColor = .labelColor
        text.insertionPointColor = .controlAccentColor
        text.drawsBackground = false
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        DispatchQueue.main.async { onReady(text) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: NSViewRepresentableContext<BarTextView>) {
        context.coordinator.parent = self
        guard let text = scroll.documentView as? NSTextView else { return }
        // The bar cleared itself after saving.
        if text.string.isEmpty { context.coordinator.measure(text) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BarTextView

        init(_ parent: BarTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            parent.onTextChange(text.string)
            measure(text)
        }

        func measure(_ text: NSTextView) {
            guard let layout = text.layoutManager, let container = text.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height
            let line = layout.defaultLineHeight(for: text.font ?? .systemFont(ofSize: 15))
            let height = min(max(used, line), BarTextView.maxHeight).rounded(.up)
            if abs(height - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = height }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let mods = NSApp.currentEvent?.modifierFlags ?? []
                if mods.contains(.shift) || mods.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMove(1)
            default:
                return false
            }
        }
    }
}
