import AppKit
import Carbon.HIToolbox

/// The system-wide shortcut that opens the notes bar (⌥Space by default).
///
/// Registered with `RegisterEventHotKey`, which needs no Accessibility
/// permission and consumes the keystroke, so it stays apart from the
/// dictation hotkey's event tap.
final class NotesHotkey {
    var onPress: (() -> Void)?

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registered: Hotkey?

    private static let signature: OSType = 0x464E_4F54 // "FNOT"

    /// Register `hotkey`, replacing any earlier one. Lone modifier keys can't
    /// be registered this way and are ignored. Returns false if macOS refused it.
    @discardableResult
    func register(_ hotkey: Hotkey) -> Bool {
        if hotkey == registered, ref != nil { return true }
        unregister()
        guard !hotkey.isModifierOnly else { return false }
        installHandler()
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(hotkey.keyCode), Self.carbonModifiers(hotkey.modifiers), id,
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else {
            Log.error("Couldn't register the notes shortcut \(hotkey.displayName) (\(status))")
            return false
        }
        ref = newRef
        registered = hotkey
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        registered = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == NotesHotkey.signature else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<NotesHotkey>.fromOpaque(userData).takeUnretainedValue()
            // The shortcut recorder is listening for keys; don't act on them.
            if !HotkeyMonitor.isSuspended {
                DispatchQueue.main.async { me.onPress?() }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
