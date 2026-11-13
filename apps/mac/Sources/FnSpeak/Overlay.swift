import AppKit
import SwiftUI

/// A small pill that shows when FnSpeak is listening, cleaning up, done or
/// stuck. Position and size come from settings. It never takes focus.
final class Overlay {
    enum State: Equatable {
        case hidden
        case listening(handsFree: Bool)
        case working
        /// Brief confirmation that the text was inserted.
        case pasted
        /// A neutral note, e.g. "Dictation is paused".
        case message(String)
        /// Something went wrong; one line saying what.
        case error(String)
        /// Picked up a spelling from the user's edit; the pill offers Undo.
        case learned(String)
        /// A meeting is being recorded; clicking opens its window.
        case meeting(since: Date)
        /// Nothing happening, with "Show pill when idle" on. Clicking opens
        /// the notes bar.
        case idle
    }

    /// One of today's meetings, in the list that opens off the pill's
    /// meeting button.
    struct AgendaItem: Identifiable {
        let id: String
        let title: String
        /// "now", "in 12 min" or "2:30 PM".
        let when: String
        /// It has a call link, which is opened along with recording.
        let hasLink: Bool
        let run: () -> Void
    }

    /// A meeting the idle pill is offering to record.
    struct MeetingPrompt: Equatable {
        let id: String
        let title: String
        /// "now" or "in 5 min"; empty for a call that was noticed.
        let when: String
        /// The button: "Record" or "Join and Record".
        let action: String
        /// A call app is in use, as opposed to a meeting coming up.
        let detected: Bool
    }

    final class Model: ObservableObject {
        @Published var state: State = .hidden
        @Published var prompt: MeetingPrompt?
        var promptAction: (() -> Void)?
        var dismissPrompt: (() -> Void)?
        @Published var level: Float = 0
        @Published var scale: CGFloat = 1
        @Published var alignment: Alignment = .bottom
        /// Degrees the pill is turned from upright, while it swings round to
        /// a new edge mid-drag. Zero at rest.
        @Published var turn: Double = 0
        var undo: (() -> Void)?
        var openMeeting: (() -> Void)?
        /// What the idle pill's menu offers.
        var actions: [PillAction] = []
        /// What's left of today's calendar.
        @Published var agenda: [AgendaItem] = []
        @Published var calendarConnected = true
        var connectCalendar: (() -> Void)?
        /// The pointer is on the pill (or the band around it).
        @Published var pointerInside = false
        /// Where the pill is in its window, top-left origin. Everything
        /// outside it lets clicks through to whatever is underneath.
        var hitFrame = CGRect.zero
        var hitFrameChanged: (() -> Void)?
    }

    /// One thing the idle pill's menu can do.
    struct PillAction: Identifiable {
        let id: String
        let symbol: String
        let label: String
        /// The tooltip: the shortcut for the same thing, where there is one.
        let hint: String
        /// Its shortcut, shown in bold on the hover label.
        var key: String?
        let run: () -> Void
    }

    /// The idle pill's menu, in order.
    var actions: [PillAction] {
        get { model.actions }
        set { model.actions = newValue }
    }

    /// Room for a row of text at the top or bottom of the screen.
    private static let panelSize = NSSize(width: 460, height: 300)
    /// On the left or right the idle pill's menu is a column, so it needs height.
    private static let sidePanelSize = NSSize(width: 460, height: 280)
    /// How far the pill sits from the side of the screen it rests on.
    fileprivate static let edgeInset: CGFloat = 4

    private let prefs = Preferences.shared
    private let model = Model()
    private var hideToken = 0
    /// While set, the pill rests on the meeting state instead of hiding.
    private var meetingSince: Date?
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = ClickThroughHostingView(rootView: PillView(model: model))
        host.dragFrame = { [weak self] in self?.restingPillFrame ?? .zero }
        host.dragMoved = { [weak self] in self?.dragMoved() }
        host.dragEnded = { [weak self] in self?.dragEnded() }
        panel.contentView = host
        model.hitFrameChanged = { [weak self] in self?.updateClickThrough() }
        // Pointer movement over other apps arrives through the first of
        // these, over the pill itself through the second.
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.updateClickThrough()
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateClickThrough()
            return event
        }
        panel.acceptsMouseMovedEvents = true
        return panel
    }()

    /// The state on show has something to click.
    private var interactive = false
    private var draggingPill = false
    private var pointerTimer: Timer?

    /// The window is much bigger than the pill, so it only takes clicks
    /// while the pointer is on the pill. Everywhere else they pass through
    /// to whatever is underneath.
    private func updateClickThrough() {
        var inside = false
        if draggingPill {
            inside = true
        } else if interactive, panel.isVisible, model.hitFrame.width > 0 {
            let frame = panel.frame, hit = model.hitFrame
            let rect = NSRect(x: frame.minX + hit.minX, y: frame.maxY - hit.maxY, width: hit.width, height: hit.height)
            inside = rect.contains(NSEvent.mouseLocation)
        }
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if model.pointerInside != inside { model.pointerInside = inside }
        // Once it's taking events the monitors can miss the pointer leaving,
        // so keep looking until it has.
        if inside, pointerTimer == nil {
            pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateClickThrough() }
        } else if !inside {
            pointerTimer?.invalidate()
            pointerTimer = nil
        }
    }

    /// Where the pointer took hold of the window, so it doesn't jump.
    private var grabOffset: NSPoint?

    /// The pill's frame while it's the idle or meeting pill, which can be
    /// picked up and moved. Messages and dictation can't.
    private var restingPillFrame: CGRect {
        switch model.state {
        case .idle, .meeting: return model.hitFrame
        default: return .zero
        }
    }

    /// The edge the pill is heading for in this drag.
    private var dragSide: String?

    /// How near the pointer is to each side, as a share of the screen, so a
    /// wide display doesn't make the top and bottom win every time.
    private func sideShares(at mouse: NSPoint) -> [String: CGFloat]? {
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame, frame.width > 0, frame.height > 0 else { return nil }
        return ["bottom": (mouse.y - frame.minY) / frame.height, "top": (frame.maxY - mouse.y) / frame.height,
                "left": (mouse.x - frame.minX) / frame.width, "right": (frame.maxX - mouse.x) / frame.width]
    }

    /// Mid-drag: the pill comes along with the pointer, and swings round to
    /// lie along whichever edge it's now nearest, before it's let go.
    private func dragMoved() {
        let mouse = NSEvent.mouseLocation
        if grabOffset == nil {
            draggingPill = true
            grabOffset = NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
            dragSide = prefs.overlayPosition == "cursor" || prefs.overlayPosition == "hidden" ? "bottom" : prefs.overlayPosition
        }
        if let shares = sideShares(at: mouse), let nearest = shares.min(by: { $0.value < $1.value }),
           let current = dragSide, nearest.key != current,
           // Clearly nearer, so it doesn't flap along a diagonal.
           nearest.value < (shares[current] ?? 1) - 0.04 {
            turnPill(to: nearest.key, from: current, at: mouse)
        }
        guard let grabOffset else { return }
        panel.setFrameOrigin(NSPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y))
    }

    /// Lay the pill along another edge while it's still in the hand. Its
    /// window is a different shape for a side than for top or bottom, so the
    /// window is swapped under the pointer and the pill turns into place.
    private func turnPill(to side: String, from old: String, at mouse: NSPoint) {
        dragSide = side
        let upright = side == "left" || side == "right"
        let size = upright ? Self.sidePanelSize : Self.panelSize
        // Where the pill sits in its window: against the edge it belongs to.
        let reach: CGFloat = 18
        let origin: NSPoint
        switch side {
        case "top": origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height + reach)
        case "left": origin = NSPoint(x: mouse.x - reach, y: mouse.y - size.height / 2)
        case "right": origin = NSPoint(x: mouse.x - size.width + reach, y: mouse.y - size.height / 2)
        default: origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - reach)
        }
        let wasUpright = old == "left" || old == "right"
        // Start turned back to how it lay, then swing to rest.
        model.turn = wasUpright == upright ? 180 : (upright ? -90 : 90)
        switch side {
        case "top": model.alignment = .top
        case "left": model.alignment = .leading
        case "right": model.alignment = .trailing
        default: model.alignment = .bottom
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        grabOffset = NSPoint(x: mouse.x - origin.x, y: mouse.y - origin.y)
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { self.model.turn = 0 }
        }
    }

    /// Let go: it never stays out in the open. It settles on the side it
    /// was heading for, and that becomes its position.
    private func dragEnded() {
        defer {
            draggingPill = false
            grabOffset = nil
            dragSide = nil
            model.turn = 0
            updateClickThrough()
        }
        var side = prefs.overlayPosition == "cursor" || prefs.overlayPosition == "hidden" ? "bottom" : prefs.overlayPosition
        // A press that never moved leaves it where it was.
        if grabOffset != nil, let dragSide {
            side = dragSide
            if prefs.overlayPosition != side { prefs.overlayPosition = side }
        }
        place(side)
    }

    /// Nothing in progress, so a toast won't cover anything.
    var isIdle: Bool {
        switch model.state {
        case .hidden, .pasted, .message, .error, .learned, .meeting, .idle: return true
        case .listening, .working: return false
        }
    }

    func showLearned(_ text: String, undo: @escaping () -> Void) {
        model.undo = { [weak self] in
            undo()
            self?.show(.hidden)
        }
        show(.learned(text))
    }

    /// For DevTools: the idle pill open on one edge, with one button hovered.
    static func previewView(alignment: Alignment, hovering: String?, agenda: [AgendaItem]? = nil) -> NSView {
        let model = Model()
        model.alignment = alignment
        model.state = .idle
        model.actions = [
            PillAction(id: "dictate", symbol: "mic.fill", label: "Dictate", hint: "Start dictating.", key: "fn") {},
            PillAction(id: "note", symbol: "square.and.pencil", label: "Note", hint: "Jot a note and start talking.") {},
            PillAction(id: "meeting", symbol: "record.circle", label: "Meeting", hint: "Record and transcribe a meeting.") {},
        ]
        model.agenda = agenda ?? []
        let side = alignment == .leading || alignment == .trailing
        let host = NSHostingView(rootView: PillView(model: model, open: true, hovering: hovering, agenda: agenda != nil).background(Color.gray))
        host.frame = NSRect(origin: .zero, size: side ? sidePanelSize : panelSize)
        return host
    }

    func showMeeting(since: Date, onTap: @escaping () -> Void) {
        meetingSince = since
        model.openMeeting = onTap
        show(.meeting(since: since))
    }

    func endMeeting() {
        meetingSince = nil
        model.openMeeting = nil
        if case .meeting = model.state { show(.hidden) }
    }

    /// Offer a meeting on the idle pill, or stop offering one.
    func setAgenda(_ items: [AgendaItem], calendarConnected: Bool, connect: @escaping () -> Void) {
        model.connectCalendar = connect
        if model.calendarConnected != calendarConnected { model.calendarConnected = calendarConnected }
        let same = model.agenda.count == items.count
            && zip(model.agenda, items).allSatisfy { $0.id == $1.id && $0.title == $1.title && $0.when == $1.when }
        if !same { model.agenda = items }
    }

    func setMeetingPrompt(_ prompt: MeetingPrompt?, action: (() -> Void)? = nil, dismiss: (() -> Void)? = nil) {
        model.promptAction = action
        model.dismissPrompt = dismiss
        guard model.prompt != prompt else { return }
        model.prompt = prompt
        refreshIdle()
    }

    /// Show or drop the idle pill after its setting changed.
    func refreshIdle() {
        switch model.state {
        case .hidden, .idle: show(.hidden)
        default: break
        }
    }

    func show(_ state: State) {
        var state = state
        if state == .hidden {
            if let since = meetingSince {
                state = .meeting(since: since)
            } else if (prefs.showPillWhenIdle || model.prompt != nil) && prefs.overlayPosition != "hidden" {
                // A meeting to offer brings the pill out even when it's kept away.
                state = .idle
            }
        }
        let wasIdle = model.state == .idle
        hideToken += 1
        let token = hideToken
        model.state = state
        switch state {
        case .learned:
            interactive = true
        case .meeting, .idle:
            model.undo = nil
            interactive = true
        default:
            model.undo = nil
            interactive = false
        }
        defer { updateClickThrough() }
        if state == .hidden {
            panel.orderOut(nil)
            return
        }

        // With the pill hidden, only problems and notes still appear.
        let position = prefs.overlayPosition
        switch state {
        case .message, .error, .learned: break
        default: if position == "hidden" { return panel.orderOut(nil) }
        }

        model.scale = Self.scale(prefs.overlaySize)
        // The idle pill can't follow the pointer around, so it waits at the
        // bottom; a dictation starting from it moves to the pointer.
        var resting = state == .idle
        if case .meeting = state { resting = true }
        if resting {
            place(position == "cursor" ? "bottom" : position)
        } else if !panel.isVisible || position != "cursor" || wasIdle {
            place(position)
        }
        panel.orderFrontRegardless()

        let lifetime: TimeInterval?
        switch state {
        case .pasted: lifetime = 0.6
        case .message: lifetime = 2.5
        case .error, .learned: lifetime = 4
        default: lifetime = nil
        }
        if let lifetime {
            DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self] in
                // A newer state replaces this one; only hide if nothing has.
                if self?.hideToken == token { self?.show(.hidden) }
            }
        }
    }

    func setLevel(_ level: Float) {
        model.level = level
    }

    private func place(_ position: String) {
        let size = position == "left" || position == "right" ? Self.sidePanelSize : Self.panelSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        var origin: NSPoint
        switch position {
        case "top":
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height)
            model.alignment = .top
        case "left":
            origin = NSPoint(x: frame.minX, y: frame.midY - size.height / 2)
            model.alignment = .leading
        case "right":
            origin = NSPoint(x: frame.maxX - size.width, y: frame.midY - size.height / 2)
            model.alignment = .trailing
        case "cursor":
            origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 8)
            model.alignment = .top
        default:
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY)
            model.alignment = .bottom
        }
        origin.x = min(max(origin.x, frame.minX), frame.maxX - size.width)
        origin.y = min(max(origin.y, frame.minY), frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private static func scale(_ size: String) -> CGFloat {
        switch size {
        case "small": return 0.85
        case "large": return 1.3
        default: return 1
        }
    }

    /// One short line for an error, for the pill.
    static func reason(for error: Error) -> String {
        if let error = error as? FnSpeakError {
            switch error {
            case .Setup(let text), .Dictation(let text), .Storage(let text), .Meeting(let text): return reason(text)
            }
        }
        return reason(error.localizedDescription)
    }

    static func reason(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("model") && (lower.contains("no whisper") || lower.contains("no parakeet") || lower.contains("not found")
            || lower.contains("no such file") || lower.contains("missing")) {
            return "Model not found"
        }
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > 70 ? String(line.prefix(67)) + "…" : line
    }
}

/// The panel never becomes key, so the first click has to count.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    /// Where the resting pill is, top-left origin; empty when it can't be moved.
    var dragFrame: (() -> CGRect)?
    var dragMoved: (() -> Void)?
    var dragEnded: (() -> Void)?

    /// How far a press has to travel before it's a drag and not a click.
    private let slop: CGFloat = 4

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Press anywhere on the pill and pull to move it. The press is followed
    /// here, in AppKit's own loop, which keeps getting the drag however far
    /// the pointer goes and wherever the window moves. A press that's let go
    /// without travelling is handed on as the click it was.
    override func mouseDown(with event: NSEvent) {
        let place = event.locationInWindow
        let point = CGPoint(x: place.x, y: bounds.height - place.y)
        guard let window, let frame = dragFrame?(), frame.width > 0, frame.contains(point) else {
            return super.mouseDown(with: event)
        }
        let start = NSEvent.mouseLocation
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if dragging { break }
                // Never left the spot: put the release back and let the
                // button under it have the whole click.
                NSApp.postEvent(next, atStart: true)
                return super.mouseDown(with: event)
            }
            let mouse = NSEvent.mouseLocation
            if !dragging, hypot(mouse.x - start.x, mouse.y - start.y) >= slop {
                dragging = true
                NSCursor.closedHand.push()
            }
            if dragging { dragMoved?() }
        }
        NSCursor.pop()
        dragEnded?()
    }
}

private struct PillView: View {
    @ObservedObject var model: Overlay.Model
    /// The idle pill is open as a menu.
    @State private var expanded: Bool
    @State private var hoverToken = 0
    /// The menu button under the pointer.
    @State private var hoveredAction: String?
    /// Today's meetings are out beside the meeting button.
    @State private var agendaOpen: Bool
    @State private var agendaToken = 0

    /// `open`, `hovering` and `agenda` stand in for the pointer, for DevTools.
    init(model: Overlay.Model, open: Bool = false, hovering: String? = nil, agenda: Bool = false) {
        self.model = model
        _expanded = State(initialValue: open)
        _hoveredAction = State(initialValue: hovering)
        _agendaOpen = State(initialValue: agenda)
    }

    var body: some View {
        Group {
            if model.state == .idle, let prompt = model.prompt {
                promptPill(prompt)
            } else if model.state == .idle {
                idlePill
            } else if case .meeting(let since) = model.state {
                meetingPill(since: since)
            } else {
                pill
            }
        }
        .onPreferenceChange(PillFrameKey.self) { frame in
            model.hitFrame = frame
            model.hitFrameChanged?()
        }
    }

    private var onSide: Bool { model.alignment == .leading || model.alignment == .trailing }

    /// At rest, a dim sliver along its edge of the screen. Under the pointer
    /// it opens into a small menu: a row at the top or bottom, a column on
    /// the left or right.
    private var idlePill: some View {
        Group {
            if expanded {
                if onSide {
                    VStack(spacing: 2 * model.scale) { menuButtons(labels: false) }
                } else {
                    HStack(spacing: 2 * model.scale) { menuButtons(labels: true) }
                }
            } else {
                // A drawn wave, not a symbol: a line stays crisp however low the pill is.
                SineWave()
                    .stroke(style: StrokeStyle(lineWidth: 1.3 * model.scale, lineCap: .round, lineJoin: .round))
                    .frame(width: 21 * model.scale, height: 2.5 * model.scale)
                    .rotationEffect(.degrees(onSide ? 90 : 0))
                    .frame(width: (onSide ? 2.5 : 21) * model.scale, height: (onSide ? 21 : 2.5) * model.scale)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, (onSide ? 4.25 : 12.5) * model.scale)
                    .padding(.vertical, (onSide ? 12.5 : 4.25) * model.scale)
            }
        }
        .padding(expanded ? 3 * model.scale : 0)
        .background(pillShape.fill(Color.black))
        .overlay(pillShape.strokeBorder(Color.white.opacity(0.9), lineWidth: 0.5))
        .modifier(AgendaSide(alignment: model.alignment, shown: expanded && agendaOpen, model: model) { expanded = false })
        // Resting on the meeting button brings out today's meetings. They
        // stay out while the pointer travels over to them, and go when it
        // lands on another button or leaves.
        .onChange(of: hoveredAction) { _, id in
            agendaToken += 1
            if id == "meeting" {
                let token = agendaToken
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if token == agendaToken { agendaOpen = true }
                }
            } else if id != nil {
                agendaOpen = false
            }
        }
        .onChange(of: expanded) { _, open in if !open { agendaOpen = false } }
        .animation(.easeOut(duration: 0.12), value: agendaOpen)
        // The pointer counts as on the pill a little way around it, and all
        // the way to the edge of the screen, so brushing its rim or the gap
        // beside it doesn't make it open and shut.
        .padding(hoverMargin)
        .contentShape(Rectangle())
        .reportsPillFrame()
        // The window tells us where the pointer is; hover tracking of its
        // own would stop the moment the window let clicks through.
        .onChange(of: model.pointerInside) { _, inside in hover(inside) }
        // Swinging round to a new edge, mid-drag.
        .rotationEffect(.degrees(model.turn))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.alignment)
        .animation(.easeOut(duration: 0.12), value: expanded)
    }

    /// Recording a meeting: the same sliver in the same place, with a red
    /// dot on it. Under the pointer it opens to say how long it's been
    /// running. A click folds the meeting's dock in and out.
    private func meetingPill(since: Date) -> some View {
        let dot = Circle().fill(Color.red).frame(width: 6 * model.scale, height: 6 * model.scale)
        let wave = SineWave()
            .stroke(style: StrokeStyle(lineWidth: 1.3 * model.scale, lineCap: .round, lineJoin: .round))
            .frame(width: 13 * model.scale, height: 2.5 * model.scale)
            .rotationEffect(.degrees(onSide ? 90 : 0))
            .frame(width: (onSide ? 2.5 : 13) * model.scale, height: (onSide ? 13 : 2.5) * model.scale)
            .foregroundStyle(.white.opacity(0.75))
        let time = TimelineView(.periodic(from: since, by: 1)) { context in
            Text(Duration.seconds(max(0, context.date.timeIntervalSince(since)))
                .formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1))))
                .monospacedDigit()
        }
        .font(.system(size: 11 * model.scale, weight: .medium))
        .foregroundStyle(.white)
        return Group {
            if onSide {
                VStack(spacing: 5 * model.scale) { dot; if expanded { time } else { wave } }
            } else {
                HStack(spacing: 5 * model.scale) { dot; if expanded { time } else { wave } }
            }
        }
        .padding(.horizontal, (expanded ? 8 : onSide ? 4.25 : 9) * model.scale)
        .padding(.vertical, (expanded ? 6 : onSide ? 9 : 4.25) * model.scale)
        .contentShape(Rectangle())
        .onTapGesture { model.openMeeting?() }
        .help("Show or fold away the meeting")
        .background(pillShape.fill(Color.black))
        .overlay(pillShape.strokeBorder(Color.white.opacity(0.9), lineWidth: 0.5))
        .padding(hoverMargin)
        .contentShape(Rectangle())
        .reportsPillFrame()
        .onChange(of: model.pointerInside) { _, inside in hover(inside) }
        // Swinging round to a new edge, mid-drag.
        .rotationEffect(.degrees(model.turn))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.alignment)
        .animation(.easeOut(duration: 0.12), value: expanded)
    }

    private var pillShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: (expanded ? 16 : 12) * model.scale, style: .continuous)
    }

    /// Room around the pill that still counts as hovering it: the gap to the
    /// screen edge on that side, and a wider band everywhere else.
    private var hoverMargin: EdgeInsets {
        let near = Overlay.edgeInset, far: CGFloat = 6
        return EdgeInsets(top: model.alignment == .top ? near : far,
                          leading: model.alignment == .leading ? near : far,
                          bottom: model.alignment == .bottom ? near : far,
                          trailing: model.alignment == .trailing ? near : far)
    }

    /// Opens at once and shuts after a beat, so the tracking area changing
    /// size under the pointer can't flick it open and shut.
    private func hover(_ inside: Bool) {
        hoverToken += 1
        if inside {
            expanded = true
            return
        }
        // Off the pill altogether, no button is under the pointer, whether
        // or not the button heard about it.
        hoveredAction = nil
        let token = hoverToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if token == hoverToken { expanded = false }
        }
    }

    /// Hover labels open away from the screen edge the pill is on.
    private var tipSide: KitTip.Side {
        switch model.alignment {
        case .leading: return .right
        case .trailing: return .left
        case .top: return .below
        default: return .above
        }
    }

    @ViewBuilder private func menuButtons(labels: Bool) -> some View {
        ForEach(model.actions) { action in
            PillMenuButton(action: action, showsLabel: labels, scale: model.scale, tip: tipSide, hovered: $hoveredAction) {
                expanded = false
                action.run()
            }
        }
    }

    /// The idle pill with a meeting to offer: what it is, and one button.
    private func promptPill(_ prompt: Overlay.MeetingPrompt) -> some View {
        let title = prompt.title.count > 30 ? String(prompt.title.prefix(29)) + "…" : prompt.title
        return HStack(spacing: 8 * model.scale) {
            Image(systemName: prompt.detected ? "record.circle" : "calendar")
                .foregroundStyle(.white.opacity(0.7))
            Text(prompt.detected ? "On a call? \(title)" : "\(title) · \(prompt.when)").lineLimit(1)
            Button(prompt.action) { model.promptAction?() }
                .buttonStyle(.plain)
                .padding(.horizontal, 9 * model.scale)
                .padding(.vertical, 3 * model.scale)
                .background(Capsule().fill(Color.white.opacity(0.2)))
            Button { model.dismissPrompt?() } label: {
                Image(systemName: "xmark").font(.system(size: 9 * model.scale, weight: .bold))
                    .frame(width: 16 * model.scale, height: 16 * model.scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
            .help("Not this one")
        }
        .font(.system(size: 12 * model.scale, weight: .medium))
        .foregroundStyle(.white)
        .padding(.leading, 12 * model.scale)
        .padding(.trailing, 6 * model.scale)
        .padding(.vertical, 5 * model.scale)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 0.5))
        .contentShape(Capsule())
        .reportsPillFrame()
        .padding(Overlay.edgeInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.alignment)
    }

    private var pill: some View {
        HStack(spacing: 8 * model.scale) {
            switch model.state {
            case .listening(let handsFree):
                LevelBars(level: model.level, scale: model.scale)
                Text(handsFree ? "Listening — press \(Preferences.shared.hotkey.displayName) to finish" : "Listening")
            case .working:
                ProgressView().controlSize(.small)
                Text("Cleaning up")
            case .pasted:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Pasted")
            case .message(let text):
                Text(text).lineLimit(2)
            case .error(let text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(text).lineLimit(1)
            case .learned(let text):
                Image(systemName: "text.badge.checkmark").foregroundStyle(.white.opacity(0.7))
                Text(text).lineLimit(1)
                Button("Undo") { model.undo?() }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.6))
                .underline()
            case .hidden, .idle, .meeting:
                EmptyView()
            }
        }
        .font(.system(size: 12 * model.scale, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14 * model.scale)
        .padding(.vertical, 8 * model.scale)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 0.5))
        .contentShape(Capsule())
        .reportsPillFrame()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.alignment)
        .padding(Overlay.edgeInset)
        .animation(.easeOut(duration: 0.12), value: model.state)
    }
}

/// Two gentle cycles of a sine wave, edge to edge.
private struct SineWave: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 48
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: rect.minX + t * rect.width,
                                y: rect.midY - sin(t * 4 * .pi) * rect.height / 2)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// Where the pill is drawn, passed up so the window knows which part of
/// itself should take clicks.
private struct PillFrameKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private extension View {
    func reportsPillFrame() -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: PillFrameKey.self, value: geometry.frame(in: .global))
        })
    }
}

/// Puts today's meetings beside the pill, on the side facing into the
/// screen, as part of the pill so the pointer can travel onto them.
private struct AgendaSide: ViewModifier {
    let alignment: Alignment
    let shown: Bool
    @ObservedObject var model: Overlay.Model
    let close: () -> Void

    func body(content: Content) -> some View {
        let gap = 8 * model.scale
        let agenda = PillAgenda(model: model, close: close).transition(.opacity)
        if !shown {
            content
        } else if alignment == .top {
            VStack(spacing: gap) { content; agenda }
        } else if alignment == .leading {
            HStack(spacing: gap) { content; agenda }
        } else if alignment == .trailing {
            HStack(spacing: gap) { agenda; content }
        } else {
            VStack(spacing: gap) { agenda; content }
        }
    }
}

/// What's left of today's calendar: each meeting with when it starts, and
/// a click records it (and opens its call link, when it has one).
private struct PillAgenda: View {
    @ObservedObject var model: Overlay.Model
    let close: () -> Void

    var body: some View {
        let scale = model.scale
        let shape = RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
        VStack(alignment: .leading, spacing: 2 * scale) {
            Text("Today")
                .font(.system(size: 10.5 * scale, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 8 * scale)
                .padding(.bottom, 2 * scale)
            if !model.calendarConnected {
                PillAgendaRow(symbol: "calendar.badge.plus", when: nil, title: "Connect your calendar", scale: scale) {
                    close()
                    model.connectCalendar?()
                }
            } else if model.agenda.isEmpty {
                HStack(spacing: 7 * scale) {
                    Image(systemName: "calendar").font(.system(size: 11 * scale))
                    Text("Calendar clear for the day")
                }
                .font(.system(size: 12 * scale, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8 * scale)
                .padding(.vertical, 5 * scale)
            } else {
                ForEach(model.agenda) { item in
                    PillAgendaRow(symbol: item.hasLink ? "video.fill" : nil, when: item.when, title: item.title, scale: scale) {
                        close()
                        item.run()
                    }
                    .help(item.hasLink ? "Join and record" : "Record this meeting")
                }
            }
        }
        .padding(8 * scale)
        .frame(width: 236 * scale, alignment: .leading)
        .background(shape.fill(Color.black))
        .overlay(shape.strokeBorder(Color.white.opacity(0.9), lineWidth: 0.5))
    }
}

private struct PillAgendaRow: View {
    /// Trailing, for a meeting with a call link; leading, when there's no time to show.
    let symbol: String?
    let when: String?
    let title: String
    let scale: CGFloat
    let run: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: run) {
            HStack(spacing: 8 * scale) {
                if let when {
                    Text(when)
                        .font(.system(size: 11 * scale, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 58 * scale, alignment: .leading)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 11 * scale))
                }
                Text(title).font(.system(size: 12 * scale, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if when != nil, let symbol {
                    Image(systemName: symbol).font(.system(size: 9.5 * scale)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 5 * scale)
            .background(RoundedRectangle(cornerRadius: 9 * scale, style: .continuous).fill(Color.white.opacity(hovering ? 0.16 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One entry in the idle pill's menu: an icon, with its name beside it when
/// there's room for a row.
private struct PillMenuButton: View {
    let action: Overlay.PillAction
    let showsLabel: Bool
    let scale: CGFloat
    /// Where its hover label goes: the side facing into the screen.
    var tip: KitTip.Side = .above
    /// The one button in the menu under the pointer, shared so two labels
    /// can never be up at once.
    @Binding var hovered: String?
    let run: () -> Void
    private var hovering: Bool { hovered == action.id }

    var body: some View {
        Button(action: run) {
            HStack(spacing: 5 * scale) {
                Image(systemName: action.symbol)
                    .font(.system(size: 12 * scale, weight: .medium))
                    .frame(width: 16 * scale, height: 16 * scale)
                if showsLabel { Text(action.label).font(.system(size: 11.5 * scale, weight: .medium)).fixedSize() }
            }
            .foregroundStyle(.white.opacity(hovering ? 1 : 0.82))
            .padding(.horizontal, (showsLabel ? 9 : 6) * scale)
            .padding(.vertical, 6 * scale)
            .background(RoundedRectangle(cornerRadius: 13 * scale, style: .continuous).fill(Color.white.opacity(hovering ? 0.16 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = action.id } else if hovered == action.id { hovered = nil }
        }
        // Out past the pill's rim, with air between.
        .kitTip(showsLabel ? action.hint : action.label, side: tip, onDark: true,
                key: showsLabel ? nil : action.key, gap: 12 * scale,
                // The meeting button brings out today's meetings in place of a label.
                active: hovering && action.id != "meeting")
        .accessibilityLabel(action.label)
    }
}

private struct LevelBars: View {
    let level: Float
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 2 * scale) {
            ForEach(0..<5) { i in
                let threshold = Float(i) / 5
                Capsule()
                    .fill(Color.white.opacity(level > threshold ? 0.95 : 0.3))
                    .frame(width: 3 * scale, height: (6 + CGFloat(i % 3) * 4) * scale)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
