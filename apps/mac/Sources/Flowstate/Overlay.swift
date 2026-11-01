import AppKit
import SwiftUI

/// A small pill near the bottom of the screen that shows when Flowstate is
/// listening or cleaning up. It never takes focus.
final class Overlay {
    enum State: Equatable {
        case hidden
        case listening(handsFree: Bool)
        case working
        case message(String)
    }

    final class Model: ObservableObject {
        @Published var state: State = .hidden
        @Published var level: Float = 0
    }

    private let model = Model()
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
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
        panel.contentView = NSHostingView(rootView: PillView(model: model))
        return panel
    }()

    func show(_ state: State) {
        model.state = state
        if state == .hidden {
            panel.orderOut(nil)
            return
        }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 130, y: frame.minY + 36))
        }
        panel.orderFrontRegardless()
        if case .message = state {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if case .message = self?.model.state { self?.show(.hidden) }
            }
        }
    }

    func setLevel(_ level: Float) {
        model.level = level
    }
}

private struct PillView: View {
    @ObservedObject var model: Overlay.Model

    var body: some View {
        HStack(spacing: 8) {
            switch model.state {
            case .listening(let handsFree):
                LevelBars(level: model.level)
                Text(handsFree ? "Listening — press Fn to finish" : "Listening")
            case .working:
                ProgressView().controlSize(.small)
                Text("Cleaning up")
            case .message(let text):
                Text(text).lineLimit(2)
            case .hidden:
                EmptyView()
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                let threshold = Float(i) / 5
                Capsule()
                    .fill(Color.white.opacity(level > threshold ? 0.95 : 0.3))
                    .frame(width: 3, height: 6 + CGFloat(i % 3) * 4)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
