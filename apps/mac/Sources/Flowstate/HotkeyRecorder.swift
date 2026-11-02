import AppKit
import SwiftUI

/// A field that captures the next shortcut you press: a key with modifiers, a
/// function key, or a lone modifier key tapped on its own. Esc stops recording.
struct HotkeyRecorder: View {
    let hotkey: Hotkey
    let onChange: (Hotkey) -> Void

    @StateObject private var model = RecorderModel()

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                model.recording ? model.stop() : model.start()
            } label: {
                Text(model.recording ? "Press a shortcut…" : hotkey.displayName)
                    .frame(minWidth: 130)
                    .foregroundStyle(model.recording ? Color.accentColor : Color.primary)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear { model.onCapture = onChange }
        .onDisappear { model.stop() }
    }
}

private final class RecorderModel: ObservableObject {
    @Published var recording = false
    @Published var error: String?
    var onCapture: ((Hotkey) -> Void)?

    private var monitor: Any?
    /// A modifier key that is down on its own; it becomes the shortcut if released without anything else.
    private var pendingModifier: UInt16?

    func start() {
        guard !recording else { return }
        recording = true
        error = nil
        pendingModifier = nil
        HotkeyMonitor.isSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        guard recording else { return }
        recording = false
        pendingModifier = nil
        HotkeyMonitor.isSuspended = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection(Hotkey.relevant)
        switch event.type {
        case .keyDown:
            pendingModifier = nil
            if event.keyCode == 53 {
                stop()
                return nil
            }
            if let problem = Hotkey.problem(keyCode: event.keyCode, modifiers: mods) {
                error = problem
                return nil
            }
            capture(Hotkey(keyCode: event.keyCode, modifiers: mods))
        case .flagsChanged:
            guard Hotkey.isModifierKey(event.keyCode) else { return nil }
            let key = Hotkey(keyCode: event.keyCode, modifiers: [])
            if key.isDown(in: event.modifierFlags) {
                let others = mods.subtracting(key.modifierFlag ?? [])
                pendingModifier = others.isEmpty ? event.keyCode : nil
            } else if pendingModifier == event.keyCode {
                capture(key)
            }
        default:
            return event
        }
        return nil
    }

    private func capture(_ hotkey: Hotkey) {
        error = nil
        stop()
        onCapture?(hotkey)
    }
}
