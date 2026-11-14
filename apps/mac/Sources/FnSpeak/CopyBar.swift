import AppKit
import SwiftUI

/// Shown on the right edge of the screen when a dictation had nowhere to go:
/// the cleaned-up text and one button to copy it. It never takes focus, so
/// clicking into a field and pasting works straight away.
final class CopyBar {
    final class Model: ObservableObject {
        @Published var text = ""
        @Published var copied = false
        var copy: () -> Void = {}
        var close: () -> Void = {}
    }

    static let width: CGFloat = 320
    /// How long it waits to be used before it goes away by itself.
    private static let lifetime: TimeInterval = 60

    private let model = Model()
    private let panel: NSPanel
    private var token = 0

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: CopyBarView(model: model))
        model.copy = { [weak self] in self?.copy() }
        model.close = { [weak self] in self?.hide() }
    }

    var isShown: Bool { panel.isVisible }

    func show(_ text: String) {
        token += 1
        let current = token
        model.text = text
        model.copied = false
        place()
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime) { [weak self] in
            if self?.token == current { self?.hide() }
        }
    }

    func hide() {
        token += 1
        panel.orderOut(nil)
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(model.text, forType: .string)
        model.copied = true
        token += 1
        let current = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            if self?.token == current { self?.hide() }
        }
    }

    /// On the right edge, centred top to bottom. With the pill parked on
    /// that edge too, it sits just inside the pill instead of over it.
    private func place() {
        guard let host = panel.contentView else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let height = min(host.fittingSize.height, area.height - 80)
        let pillInset: CGFloat = Preferences.shared.overlayPosition == "right" ? 56 : 0
        panel.setFrame(NSRect(x: area.maxX - Self.width - 12 - pillInset, y: area.midY - height / 2, width: Self.width, height: height), display: true)
    }

    /// For DevTools.
    static func previewView(text: String, copied: Bool = false) -> NSView {
        let model = Model()
        model.text = text
        model.copied = copied
        let host = NSHostingView(rootView: CopyBarView(model: model).padding(20).background(Color.gray))
        host.frame = NSRect(origin: .zero, size: NSSize(width: width + 40, height: host.fittingSize.height))
        return host
    }
}

private struct CopyBarView: View {
    @ObservedObject var model: CopyBar.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.cursor").font(.system(size: 11, weight: .semibold))
                Text("No text box was selected").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button { model.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .foregroundStyle(.white.opacity(0.65))

            ScrollView {
                Text(model.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)

            Button { model.copy() } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
                    Text(model.copied ? "Copied" : "Copy")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: CopyBar.width)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.9), lineWidth: 0.5))
    }
}
