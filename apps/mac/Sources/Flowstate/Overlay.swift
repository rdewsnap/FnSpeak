import AppKit
import SwiftUI

/// A small pill that shows when Flowstate is listening, cleaning up, done or
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
    }

    final class Model: ObservableObject {
        @Published var state: State = .hidden
        @Published var level: Float = 0
        @Published var scale: CGFloat = 1
        @Published var alignment: Alignment = .bottom
        var undo: (() -> Void)?
        var openMeeting: (() -> Void)?
    }

    private static let panelSize = NSSize(width: 460, height: 84)
    private static let edgeGap: CGFloat = 36

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
        return panel
    }()

    /// Nothing in progress, so a toast won't cover anything.
    var isIdle: Bool {
        switch model.state {
        case .hidden, .pasted, .message, .error, .learned, .meeting: return true
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

    func show(_ state: State) {
        var state = state
        if state == .hidden, let since = meetingSince { state = .meeting(since: since) }
        hideToken += 1
        let token = hideToken
        model.state = state
        if case .learned = state {
            panel.ignoresMouseEvents = false
        } else if case .meeting = state {
            model.undo = nil
            panel.ignoresMouseEvents = false
        } else {
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
        if !panel.isVisible || position != "cursor" { place(position) }
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
        let size = Self.panelSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        var origin: NSPoint
        switch position {
        case "top":
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 12)
            model.alignment = .top
        case "cursor":
            origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 8)
            model.alignment = .top
        default:
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + Self.edgeGap - 20)
            model.alignment = .bottom
        }
        origin.x = min(max(origin.x, frame.minX), frame.maxX - size.width)
        origin.y = min(max(origin.y, frame.minY), frame.maxY - size.height)
        panel.setFrameOrigin(origin)
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
        if let error = error as? FlowstateError {
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

    var body: some View {
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
            case .hidden:
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
        .onTapGesture { model.openMeeting?() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.alignment)
        .padding(.vertical, 12)
        .animation(.easeOut(duration: 0.12), value: model.state)
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
