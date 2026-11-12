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
        var undo: (() -> Void)?
        var openMeeting: (() -> Void)?
        /// What the idle pill's menu offers.
        var actions: [PillAction] = []
        /// The idle pill is being dragged, and then let go.
        var dragged: (() -> Void)?
        var dropped: (() -> Void)?
    }

    /// One thing the idle pill's menu can do.
    struct PillAction: Identifiable {
        let id: String
        let symbol: String
        let label: String
        /// The tooltip: the shortcut for the same thing, where there is one.
        let hint: String
        let run: () -> Void
    }

    /// The idle pill's menu, in order.
    var actions: [PillAction] {
        get { model.actions }
        set { model.actions = newValue }
    }

    /// Room for a row of text at the top or bottom of the screen.
    private static let panelSize = NSSize(width: 460, height: 84)
    /// On the left or right the idle pill's menu is a column, so it needs height.
    private static let sidePanelSize = NSSize(width: 460, height: 240)
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
        panel.contentView = ClickThroughHostingView(rootView: PillView(model: model))
        model.dragged = { [weak self] in self?.followPointer() }
        model.dropped = { [weak self] in self?.dropAtNearestSide() }
        return panel
    }()

    /// Mid-drag: keep the pill under the pointer.
    private func followPointer() {
        let mouse = NSEvent.mouseLocation
        model.alignment = .center
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2))
    }

    /// Let go: the pill settles on whichever side of the screen is closest,
    /// and that becomes its position.
    private func dropAtNearestSide() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return place(prefs.overlayPosition) }
        let sides: [(String, CGFloat)] = [
            ("bottom", mouse.y - frame.minY), ("top", frame.maxY - mouse.y),
            ("left", mouse.x - frame.minX), ("right", frame.maxX - mouse.x),
        ]
        let side = sides.min { $0.1 < $1.1 }?.0 ?? "bottom"
        if prefs.overlayPosition != side { prefs.overlayPosition = side }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            place(side, animated: true)
        }
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
            panel.ignoresMouseEvents = false
        case .meeting, .idle:
            model.undo = nil
            panel.ignoresMouseEvents = false
        default:
            model.undo = nil
            panel.ignoresMouseEvents = true
        }
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
        if state == .idle {
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

    private func place(_ position: String, animated: Bool = false) {
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
        if animated {
            panel.animator().setFrame(NSRect(origin: origin, size: size), display: true)
        } else {
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct PillView: View {
    @ObservedObject var model: Overlay.Model
    /// The idle pill is open as a menu.
    @State private var expanded = false
    @State private var hoverToken = 0
    /// A drag just ended, so the click that comes with it isn't a click.
    @State private var dragging = false

    var body: some View {
        if model.state == .idle, let prompt = model.prompt {
            promptPill(prompt)
        } else if model.state == .idle {
            idlePill
        } else {
            pill
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
                    .frame(width: 26 * model.scale, height: 2.5 * model.scale)
                    .rotationEffect(.degrees(onSide ? 90 : 0))
                    .frame(width: (onSide ? 2.5 : 26) * model.scale, height: (onSide ? 26 : 2.5) * model.scale)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, (onSide ? 4.25 : 16) * model.scale)
                    .padding(.vertical, (onSide ? 16 : 4.25) * model.scale)
            }
        }
        .padding(expanded ? 3 * model.scale : 0)
        .background(pillShape.fill(Color.black.opacity(expanded ? 0.86 : 0.4)))
        .overlay(pillShape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        // The pointer counts as on the pill a little way around it, and all
        // the way to the edge of the screen, so brushing its rim or the gap
        // beside it doesn't make it open and shut.
        .padding(hoverMargin)
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .gesture(drag)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.alignment)
        .animation(.easeOut(duration: 0.12), value: expanded)
    }

    private var pillShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: (expanded ? 16 : 12) * model.scale, style: .continuous)
    }

    /// Room around the pill that still counts as hovering it: the gap to the
    /// screen edge on that side, and a wider band everywhere else.
    private var hoverMargin: EdgeInsets {
        let near = Overlay.edgeInset, far: CGFloat = 10
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
            if !dragging { expanded = true }
            return
        }
        let token = hoverToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if token == hoverToken { expanded = false }
        }
    }

    @ViewBuilder private func menuButtons(labels: Bool) -> some View {
        ForEach(model.actions) { action in
            PillMenuButton(action: action, showsLabel: labels, scale: model.scale) {
                expanded = false
                action.run()
            }
        }
    }

    /// Drag the pill to any side of the screen. The window moves with the
    /// pointer, so the pointer is read from the screen, not the gesture.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { _ in
                dragging = true
                expanded = false
                model.dragged?()
            }
            .onEnded { _ in
                model.dropped?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { dragging = false }
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
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .contentShape(Capsule())
        .gesture(drag)
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
            case .meeting(let since):
                Circle().fill(Color.red).frame(width: 8 * model.scale, height: 8 * model.scale)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Duration.seconds(max(0, context.date.timeIntervalSince(since)))
                        .formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1))))
                        .monospacedDigit()
                }
            case .hidden, .idle:
                EmptyView()
            }
        }
        .font(.system(size: 12 * model.scale, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14 * model.scale)
        .padding(.vertical, 8 * model.scale)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .contentShape(Capsule())
        .onTapGesture { if case .meeting = model.state { model.openMeeting?() } }
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

/// One entry in the idle pill's menu: an icon, with its name beside it when
/// there's room for a row.
private struct PillMenuButton: View {
    let action: Overlay.PillAction
    let showsLabel: Bool
    let scale: CGFloat
    let run: () -> Void
    @State private var hovering = false

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
        .onHover { hovering = $0 }
        .help(showsLabel ? action.hint : "\(action.label). \(action.hint)")
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
