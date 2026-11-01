import AppKit

/// Watches the Fn (globe) key.
///
/// - Hold Fn: record while held, transcribe on release.
/// - Double-tap Fn: hands-free; recording continues until Fn is pressed again.
/// - Fn used as a modifier (Fn+arrow, Fn+F-key) cancels instead of dictating.
///
/// Global key monitoring needs the Accessibility permission.
final class HotkeyMonitor {
    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    /// ⌃⌥Z: swap the last dictation for its raw transcript.
    var onSwapToRaw: (() -> Void)?

    private static let fnKeyCode: UInt16 = 63
    private static let zKeyCode: UInt16 = 6
    /// A press shorter than this is a tap, not a hold.
    private let tapMax: TimeInterval = 0.25
    /// Second tap must come within this long for a double-tap.
    private let doubleTapWindow: TimeInterval = 0.35

    private var monitors: [Any] = []
    private var fnDown = false
    private var pressedAt = Date.distantPast
    private var handsFree = false
    private var awaitingSecondTap = false
    private var usedAsModifier = false
    private var tapTimer: Timer?

    func start() {
        let flags: (NSEvent) -> Void = { [weak self] in self?.handleFlags($0) }
        let keys: (NSEvent) -> Void = { [weak self] in self?.handleKey($0) }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { keys($0); return $0 } as Any)
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func handleFlags(_ event: NSEvent) {
        guard event.keyCode == Self.fnKeyCode else { return }
        let down = event.modifierFlags.contains(.function)
        guard down != fnDown else { return }
        fnDown = down
        down ? fnPressed() : fnReleased()
    }

    private func fnPressed() {
        usedAsModifier = false
        if handsFree {
            handsFree = false
            onFinish?()
            return
        }
        if awaitingSecondTap {
            // Double-tap: recording is already running from the first tap.
            awaitingSecondTap = false
            tapTimer?.invalidate()
            handsFree = true
            return
        }
        pressedAt = Date()
        onStart?()
    }

    private func fnReleased() {
        if handsFree { return }
        if usedAsModifier {
            onCancel?()
            return
        }
        let held = Date().timeIntervalSince(pressedAt)
        if held >= tapMax {
            onFinish?()
            return
        }
        // A quick tap: wait to see whether it's the first half of a double-tap.
        awaitingSecondTap = true
        tapTimer?.invalidate()
        tapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapWindow, repeats: false) { [weak self] _ in
            guard let self, self.awaitingSecondTap else { return }
            self.awaitingSecondTap = false
            self.onCancel?()
        }
    }

    private func handleKey(_ event: NSEvent) {
        if fnDown && !handsFree {
            usedAsModifier = true
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == Self.zKeyCode && mods == [.control, .option] {
            onSwapToRaw?()
        }
    }
}
