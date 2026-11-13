import AppKit
import Combine
import SwiftUI

/// The meeting, docked to the side of the screen. It slides out of the edge
/// the pill lives on (the right, when the pill is top or bottom), runs the
/// full height, and folds back into the edge while the meeting carries on.
/// Naming it, the live transcript, notes and the summary all happen here;
/// the arrow at the top hands over to the main window.
final class MeetingDock: NSObject {
    enum Tab: Hashable { case notes, transcript, summary }

    final class State: ObservableObject {
        /// False while folded into the edge.
        @Published var shown = false
        /// Docked to the left edge instead of the right.
        @Published var onLeft = false
        /// The pill sits on the dock's own edge, so content keeps clear of it.
        @Published var sharesEdgeWithPill = false
        @Published var tab = Tab.transcript
    }

    static let width: CGFloat = 400
    /// Clear space on the inner side of the window, for the shadow.
    static let margin: CGFloat = 24
    private static let foldTime = 0.24

    private weak var controller: MeetingController?
    private let prefs = Preferences.shared
    private let state = State()
    private var subscription: AnyCancellable?
    private var hideToken = 0

    private lazy var panel: NotesPanel = {
        let panel = NotesPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width + Self.margin, height: 600),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        // Under the pill, which rides on the dock's edge.
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The dock draws its own, so it can slide away with it.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        if let controller {
            let view = MeetingDockView(
                controller: controller, state: state,
                fold: { [weak self] in self?.hide() },
                openApp: { [weak self] in self?.openApp() }
            )
            let host = NSHostingView(rootView: AnyView(view))
            host.sizingOptions = []
            panel.contentView = host
        }
        return panel
    }()

    init(controller: MeetingController) {
        self.controller = controller
        super.init()
        subscription = controller.$phase
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.phaseChanged(phase) }
    }

    var isOut: Bool { panel.isVisible && state.shown }

    func toggle() {
        isOut ? hide() : show()
    }

    /// Slide out of the edge. Nothing to show, nothing happens.
    func show(tab: Tab? = nil) {
        guard let controller, Self.hasContent(controller) else { return }
        if let tab { state.tab = tab }
        hideToken += 1
        fit()
        if !panel.isVisible { state.shown = false }
        if controller.phase == .setup {
            // The title is waiting to be typed.
            panel.makeKeyAndOrderFront(nil)
        } else {
            // Don't take the keyboard from the call.
            panel.orderFrontRegardless()
        }
        DispatchQueue.main.async { self.state.shown = true }
    }

    /// Fold back into the edge. The meeting carries on.
    func hide() {
        guard panel.isVisible else { return }
        state.shown = false
        hideToken += 1
        let token = hideToken
        // Put away before it was started: the meeting isn't happening.
        if controller?.phase == .setup { controller?.cancelSetup() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.foldTime) { [weak self] in
            guard let self, token == self.hideToken else { return }
            self.panel.orderOut(nil)
        }
    }

    /// Hand over to the main window, on this meeting.
    private func openApp() {
        guard let controller else { return }
        let id = controller.finished?.id
        hide()
        controller.showInApp(id)
    }

    /// For DevTools: the dock as it stands, out and ready to be drawn.
    static func previewView(controller: MeetingController, onLeft: Bool, tab: Tab = .transcript) -> NSView {
        let state = State()
        state.tab = tab
        state.shown = true
        state.onLeft = onLeft
        state.sharesEdgeWithPill = true
        let view = MeetingDockView(controller: controller, state: state, fold: {}, openApp: {})
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: width + margin, height: 820)
        return host
    }

    private static func hasContent(_ controller: MeetingController) -> Bool {
        controller.phase != .idle || controller.finished != nil || controller.error != nil
    }

    private func phaseChanged(_ phase: MeetingController.Phase) {
        switch phase {
        case .processing:
            // Stopped: what's next is the summary.
            state.tab = .summary
        case .recording:
            state.tab = .transcript
        case .idle:
            if let controller, !Self.hasContent(controller) { hide() }
        case .setup, .starting:
            break
        }
    }

    /// Flush against the pill's edge of the screen, full height.
    private func fit() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let position = prefs.overlayPosition
        state.onLeft = position == "left"
        state.sharesEdgeWithPill = position == "left" || position == "right"
        let width = Self.width + Self.margin
        let x = state.onLeft ? visible.minX : visible.maxX - width
        panel.setFrame(NSRect(x: x, y: visible.minY, width: width, height: visible.height), display: true)
    }
}

// MARK: - The dock

private struct MeetingDockView: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject var state: MeetingDock.State
    let fold: () -> Void
    let openApp: () -> Void

    var body: some View {
        let radius = Theme.Radius.large
        // Square against the screen edge, rounded on the side facing in.
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: state.onLeft ? 0 : radius, bottomLeadingRadius: state.onLeft ? 0 : radius,
            bottomTrailingRadius: state.onLeft ? radius : 0, topTrailingRadius: state.onLeft ? radius : 0,
            style: .continuous
        )
        MeetingDockContent(controller: controller, state: state, fold: fold, openApp: openApp)
            // The pill rides on this edge; keep text out from under it.
            .padding(state.onLeft ? .leading : .trailing, state.sharesEdgeWithPill ? 14 : 0)
            .frame(width: MeetingDock.width)
            .frame(maxHeight: .infinity)
            .background(shape.fill(Theme.raised))
            .overlay(shape.strokeBorder(Theme.line, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.3), radius: 12, x: state.onLeft ? 3 : -3, y: 0)
            .padding(state.onLeft ? .trailing : .leading, MeetingDock.margin)
            // In from the edge and back out to it.
            .offset(x: state.shown ? 0 : (state.onLeft ? -1 : 1) * (MeetingDock.width + MeetingDock.margin))
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: state.shown)
            .skinned()
    }
}

private struct MeetingDockContent: View {
    @ObservedObject var controller: MeetingController
    @ObservedObject var state: MeetingDock.State
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var downloader = ModelDownloader.shared
    let fold: () -> Void
    let openApp: () -> Void

    @FocusState private var titleFocused: Bool
    @FocusState private var padFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.m)
            switch controller.phase {
            case .setup:
                setup.padding(Theme.Space.xl)
                Spacer(minLength: 0)
            case .starting:
                titleBlock.padding(.horizontal, Theme.Space.xl).padding(.top, Theme.Space.l)
                waiting("Starting…")
            case .recording, .processing:
                meeting
            case .idle:
                if controller.finished != nil {
                    meeting
                } else {
                    failure.padding(Theme.Space.xl)
                    Spacer(minLength: 0)
                }
            }
        }
        .scrollIndicators(.never)
    }

    // MARK: Top bar

    /// The arrow points into the screen, where the app opens; the fold
    /// button points at the edge the dock folds into.
    private var topBar: some View {
        let open = Button(action: openApp) {
            Image(systemName: state.onLeft ? "chevron.right" : "chevron.left")
        }
        .buttonStyle(KitButtonStyle(kind: .secondary, size: .small))
        .kitTip("Open in FnSpeak", anchor: state.onLeft ? .trailing : .leading)
        .accessibilityLabel("Open in FnSpeak")
        let close = Button(action: fold) {
            Image(systemName: state.onLeft ? "arrow.left.to.line" : "arrow.right.to.line")
        }
        .buttonStyle(KitButtonStyle(kind: .secondary, size: .small))
        .kitTip(controller.phase == .recording ? "Fold away. Recording carries on." : "Fold away",
                anchor: state.onLeft ? .leading : .trailing)
        .accessibilityLabel("Fold away")
        return HStack(spacing: Theme.Space.s) {
            if state.onLeft { close } else { open }
            Spacer()
            if state.onLeft { open } else { close }
        }
    }

    // MARK: Title

    private var title: String {
        let name = controller.finished?.title ?? controller.current?.title ?? controller.draft.title
        return name.isEmpty ? "Meeting" : name
    }

    private var people: [String] {
        controller.finished?.participants ?? controller.draft.participants
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.Fonts.title)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                status
                if !people.isEmpty {
                    Text(people.count == 1 ? people[0] : "\(people[0]) and \(people.count - 1) more")
                        .font(Theme.Fonts.support).foregroundStyle(Theme.textSoft).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var status: some View {
        switch controller.phase {
        case .recording:
            if let since = controller.startedAt {
                HStack(spacing: 6) {
                    Circle().fill(Theme.critical).frame(width: 8, height: 8)
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(MeetingController.timestamp(ms: Int64(context.date.timeIntervalSince(since) * 1000)))
                            .font(Theme.Fonts.support.monospacedDigit())
                            .foregroundStyle(Theme.textSoft)
                    }
                }
            }
        case .processing:
            Text("Stopped").font(Theme.Fonts.support).foregroundStyle(Theme.textSoft)
        default:
            if let meeting = controller.finished {
                Text(Date(timeIntervalSince1970: TimeInterval(meeting.startedAt)).formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Fonts.support).foregroundStyle(Theme.textSoft)
            }
        }
    }

    // MARK: Before it starts

    private var setup: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("New meeting").font(Theme.Fonts.title)
            TextField("Title", text: $controller.draft.title, prompt: Text(MeetingController.defaultTitle()))
                .textFieldStyle(KitTextFieldStyle())
                .focused($titleFocused)
                .onSubmit { controller.beginRecording() }
            if controller.draft.calendarEventId != nil || !controller.draft.participants.isEmpty {
                Label(who, systemImage: "calendar")
                    .font(Theme.Fonts.support).foregroundStyle(Theme.textSoft)
                    .lineLimit(2)
            }
            Text(prefs.meetingSystemAudio
                 ? "Records your microphone and the call's audio. Only the transcript is kept."
                 : "Records your microphone only.")
                .font(Theme.Fonts.support).foregroundStyle(Theme.textSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Button("Start recording") { controller.beginRecording() }
                    .buttonStyle(KitButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", action: fold)
                    .buttonStyle(.kit)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .onAppear { titleFocused = true }
    }

    /// "From your calendar" and who's on it, as far as there's room.
    private var who: String {
        let people = controller.draft.participants
        guard !people.isEmpty else { return "From your calendar" }
        let shown = people.prefix(3).joined(separator: ", ")
        return people.count > 3 ? "With \(shown) and \(people.count - 3) more" : "With \(shown)"
    }

    private func waiting(_ text: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            ProgressView().controlSize(.small)
            Text(text).font(Theme.Fonts.support).foregroundStyle(Theme.textSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// It didn't start. Say so here, by the edge, and offer another go.
    private var failure: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("The meeting didn't start").font(Theme.Fonts.title)
                .fixedSize(horizontal: false, vertical: true)
            if let error = controller.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Theme.Fonts.support).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.s) {
                Button("Try again") {
                    controller.error = nil
                    controller.requestStart()
                }
                .buttonStyle(KitButtonStyle(kind: .primary))
                Button("Close") {
                    controller.error = nil
                    fold()
                }
                .buttonStyle(.kit)
            }
        }
    }

    // MARK: The meeting

    private var meeting: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBlock
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.l)
            tabs
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.l)
            Rectangle().fill(Theme.line).frame(height: 1)
            Group {
                switch state.tab {
                case .notes: notesTab
                case .transcript: transcript
                case .summary: summary
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
    }

    /// Underlined tabs, as in the main window's pages.
    private var tabs: some View {
        HStack(spacing: Theme.Space.xl) {
            tab(.notes, "My notes")
            tab(.transcript, "Transcript")
            tab(.summary, "Summary")
            Spacer(minLength: 0)
        }
    }

    private func tab(_ value: MeetingDock.Tab, _ label: String) -> some View {
        let selected = state.tab == value
        return Button {
            state.tab = value
        } label: {
            Text(label)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.text : Theme.textSoft)
                .padding(.bottom, Theme.Space.s)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? Theme.text : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                    if controller.segments.isEmpty {
                        Text(controller.phase == .recording
                             ? "The transcript appears here as people speak."
                             : "Nothing was transcribed.")
                            .font(Theme.Fonts.support).foregroundStyle(Theme.textSoft)
                    }
                    ForEach(controller.segments, id: \.id) { segment in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Theme.Space.s) {
                                Text(MeetingController.speakerName(segment.speaker))
                                    .font(Theme.Fonts.caption.weight(.semibold))
                                    .foregroundStyle(MeetingSegmentRow.color(for: segment.speaker))
                                Text(MeetingController.timestamp(ms: segment.startedMs))
                                    .font(Theme.Fonts.caption.monospacedDigit())
                                    .foregroundStyle(Theme.textFaint)
                            }
                            Text(segment.text.isEmpty ? segment.raw : segment.text)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .id(segment.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.xl)
            }
            .onChange(of: controller.segments.count) {
                guard controller.phase == .recording, let last = controller.segments.last else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// One pad for the meeting: type anything, any time. It's saved with
    /// the meeting as it's typed and read when the summary is written.
    private var notesTab: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $controller.pad)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .focused($padFocused)
            if controller.pad.isEmpty {
                Text(controller.phase == .recording
                     ? "Jot anything down. Your notes stay with this meeting and help shape its summary."
                     : "No notes for this meeting. Anything you add is used the next time it's summarized.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textFaint)
                    // Where the editor puts its first character.
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, Theme.Space.xl - 5)
        .padding(.vertical, Theme.Space.l)
        .contentShape(Rectangle())
        .onTapGesture { padFocused = true }
    }

    @ViewBuilder
    private var summary: some View {
        switch controller.phase {
        case .recording:
            Text("The summary and action items are written when you stop.")
                .font(Theme.Fonts.support).foregroundStyle(Theme.textSoft)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.xl)
        case .processing:
            waiting("Finishing the transcript and writing the summary. This can take a minute.")
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if let error = controller.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(Theme.Fonts.support).foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let meeting = controller.finished {
                        if meeting.writtenSummary == nil, downloader.revision >= 0, ModelLocator.summaryNeedsModel {
                            MeetingSummaryModelNotice()
                        } else if let md = meeting.writtenSummary {
                            MeetingMarkdown(markdown: md, skippingSections: meeting.actionItems.isEmpty ? [] : ["action item"])
                                .textSelection(.enabled)
                        } else {
                            Text("This meeting has no summary. The transcript is saved.")
                                .font(Theme.Fonts.support).foregroundStyle(Theme.textSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !meeting.actionItems.isEmpty {
                            Text("Action items").font(Theme.Fonts.heading)
                            ForEach(Array(meeting.actionItems.enumerated()), id: \.offset) { index, item in
                                Toggle(isOn: Binding(
                                    get: { item.done },
                                    set: { controller.setActionItem(index, done: $0, in: meeting.id) { _ in } }
                                )) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.task)
                                            .strikethrough(item.done)
                                            .foregroundStyle(item.done ? Theme.textSoft : Theme.text)
                                            .fixedSize(horizontal: false, vertical: true)
                                        let detail = [item.owner, item.due.map { "due \($0)" }].compactMap { $0 }
                                        if !detail.isEmpty {
                                            Text(detail.joined(separator: " · "))
                                                .font(Theme.Fonts.caption).foregroundStyle(Theme.textSoft)
                                        }
                                    }
                                }
                                .toggleStyle(.kitCheckbox)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.xl)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if controller.phase == .recording {
                if let note = controller.systemAudioNote {
                    Text(note).font(Theme.Fonts.support).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = controller.error {
                    Text(error).font(Theme.Fonts.support).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Theme.Space.s) {
                    Button {
                        controller.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(KitButtonStyle(kind: .destructive))
                    .kitTip("Stop recording and write the summary", side: .above, anchor: .leading)
                    Spacer()
                }
            } else if controller.phase == .idle, controller.finished != nil {
                HStack(spacing: Theme.Space.s) {
                    Button("Open in FnSpeak", action: openApp)
                        .buttonStyle(KitButtonStyle(kind: .primary))
                    Button("Done", action: fold)
                        .buttonStyle(.kit)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, controller.phase == .processing ? 0 : Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if controller.phase != .processing { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }
}
