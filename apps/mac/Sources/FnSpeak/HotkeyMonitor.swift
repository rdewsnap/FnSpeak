import AppKit
import ApplicationServices

/// Watches the dictation hotkey (Fn by default, see `Hotkey`).
///
/// How a press behaves depends on the trigger style in settings:
/// - hold: record while held, transcribe on release.
/// - toggle: press to start, press again to finish.
/// - both: hold to talk, or double-tap for hands-free and press again to finish.
///
/// A lone modifier key used as a modifier (Fn+arrow, Right ⌘+C) cancels
/// instead of dictating. Esc cancels a recording.
///
/// Events come from an event tap when Accessibility is granted, which lets
/// the hotkey and Esc be consumed instead of reaching the frontmost app.
/// Without it, plain NSEvent monitors still observe them.
final class HotkeyMonitor {
    /// Return false if recording didn't start (paused, excluded app, no mic).
    var onStart: (() -> Bool)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    /// A double-tap switched a running recording to hands-free.
    var onHandsFree: (() -> Void)?
    /// ⌃⌥Z: swap the last dictation for its raw transcript.
    var onSwapToRaw: (() -> Void)?

    /// Set while the shortcut recorder is capturing keys.
    static var isSuspended = false

    private static let zKeyCode: UInt16 = 6
    private static let escKeyCode: UInt16 = 53
    /// Second tap must come within this long for a double-tap.
    private let doubleTapWindow: TimeInterval = 0.35
    /// A press shorter than this is a tap, not a hold.
    private let tapMax: TimeInterval = 0.25

    private let prefs = Preferences.shared
    private var monitors: [Any] = []
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var upgradeTimer: Timer?

    private var triggerDown = false
    /// A recording started by this monitor is running.
    private var active = false
    /// When the key went down, on the event's own clock (seconds since boot).
    /// Events can sit in the queue while the microphone starts, so the time
    /// they are handled says nothing about how long the key was held.
    private var pressedAt: TimeInterval = 0
    private var handsFree = false
    /// The running recording was started from the pill, not by this monitor.
    private var startedElsewhere = false
    private var awaitingSecondTap = false
    private var usedAsModifier = false
    /// The current press was refused or cancelled; ignore it until released.
    private var ignoreUntilRelease = false
    /// A combo's key-down was consumed, so its key-up should be too.
    private var comboKeyDown = false
    private var tapTimer: Timer?

    private enum Style: String { case hold, toggle, both }
    private var style: Style { Style(rawValue: prefs.triggerStyle) ?? .both }

    func start() {
        if installTap() { return }
        installMonitors()
        // Accessibility is often granted after launch; switch to the tap when it is.
        upgradeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted(), self.installTap() else { return }
            self.removeMonitors()
            timer.invalidate()
        }
    }

    func stop() {
        upgradeTimer?.invalidate()
        removeMonitors()
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
    }

    /// A recording was started some other way (the pill's menu) and runs
    /// hands-free: the next press of the hotkey finishes it.
    func recordingStartedElsewhere() {
        active = true
        startedElsewhere = true
    }

    /// The recording ended some way other than the hotkey (auto-stop, a menu action).
    func recordingEnded() {
        startedElsewhere = false
        active = false
        handsFree = false
        awaitingSecondTap = false
        tapTimer?.invalidate()
        if triggerDown { ignoreUntilRelease = true }
    }

    // MARK: - Event sources

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] in _ = self?.process($0) }
        let types: [NSEvent.EventTypeMask] = [.flagsChanged, .keyDown, .keyUp]
        for type in types {
            monitors.append(NSEvent.addGlobalMonitorForEvents(matching: type, handler: handler) as Any)
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: type) { handler($0); return $0 } as Any)
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func installTap() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().tapped(type, event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
        return true
    }

    private func tapped(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.error("Hotkey tap was switched off by macOS (\(type == .tapDisabledByTimeout ? "too slow" : "by input")); switching it back on")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let nsEvent = NSEvent(cgEvent: event), process(nsEvent) else { return Unmanaged.passUnretained(event) }
        return nil
    }

    // MARK: - Events

    /// Returns true if the event should be consumed.
    private func process(_ event: NSEvent) -> Bool {
        guard !Self.isSuspended else { return false }
        switch event.type {
        case .flagsChanged: return handleFlags(event)
        case .keyDown: return handleKeyDown(event)
        case .keyUp: return handleKeyUp(event)
        default: return false
        }
    }

    private func handleFlags(_ event: NSEvent) -> Bool {
        let hotkey = prefs.hotkey
        if hotkey.isModifierOnly {
            if event.keyCode == hotkey.keyCode {
                setTrigger(hotkey.isDown(in: event.modifierFlags), at: event.timestamp)
            }
        } else if triggerDown {
            // Let go of the modifiers before the key: that ends the press too.
            let held = event.modifierFlags.intersection(Hotkey.relevant)
            if !held.isSuperset(of: hotkey.modifiers) { setTrigger(false, at: event.timestamp) }
        }
        return false
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(Hotkey.relevant)
        if event.keyCode == Self.escKeyCode && mods.isEmpty && prefs.escapeCancels && active {
            cancel()
            return true
        }
        if event.keyCode == Self.zKeyCode && mods == [.control, .option] {
            onSwapToRaw?()
            return false
        }

        let hotkey = prefs.hotkey
        if hotkey.isModifierOnly {
            if triggerDown && !handsFree { usedAsModifier = true }
            return false
        }
        guard event.keyCode == hotkey.keyCode, mods == hotkey.modifiers else { return false }
        comboKeyDown = true
        if !event.isARepeat { setTrigger(true, at: event.timestamp) }
        return true
    }

    private func handleKeyUp(_ event: NSEvent) -> Bool {
        let hotkey = prefs.hotkey
        guard !hotkey.isModifierOnly, event.keyCode == hotkey.keyCode else { return false }
        setTrigger(false, at: event.timestamp)
        let consume = comboKeyDown
        comboKeyDown = false
        return consume
    }

    // MARK: - Trigger

    private func setTrigger(_ down: Bool, at time: TimeInterval) {
        guard down != triggerDown else { return }
        triggerDown = down
        down ? pressed(at: time) : released(at: time)
    }

    private func pressed(at time: TimeInterval) {
        usedAsModifier = false
        ignoreUntilRelease = false
        if startedElsewhere {
            startedElsewhere = false
            ignoreUntilRelease = true
            return finish()
        }
        switch style {
        case .toggle:
            active ? finish() : begin()
        case .hold:
            pressedAt = time
            begin()
        case .both:
            if handsFree {
                finish()
            } else if awaitingSecondTap {
                // Double-tap: recording is already running from the first tap.
                awaitingSecondTap = false
                tapTimer?.invalidate()
                handsFree = true
                Log.debug("Hotkey: double-tap, hands-free")
                onHandsFree?()
            } else {
                pressedAt = time
                begin()
            }
        }
    }

    private func released(at time: TimeInterval) {
        if ignoreUntilRelease {
            ignoreUntilRelease = false
            return
        }
        guard active else { return }
        switch style {
        case .toggle:
            return
        case .hold:
            usedAsModifier ? cancel() : finish()
        case .both:
            if handsFree { return }
            if usedAsModifier {
                cancel()
            } else if time - pressedAt >= tapMax {
                finish()
            } else {
                // A quick tap: wait to see whether it's the first half of a double-tap.
                awaitingSecondTap = true
                tapTimer?.invalidate()
                tapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapWindow, repeats: false) { [weak self] _ in
                    guard let self, self.awaitingSecondTap else { return }
                    self.cancel()
                }
            }
        }
    }

    private func begin() {
        if onStart?() == true {
            active = true
        } else {
            ignoreUntilRelease = true
        }
    }

    private func finish() {
        active = false
        handsFree = false
        onFinish?()
    }

    private func cancel() {
        recordingEnded()
        onCancel?()
    }
}
