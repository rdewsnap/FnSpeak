import AppKit

/// The key that starts dictation: either a lone modifier key (Fn, Right ⌥…)
/// or a key with modifiers (⌃Space).
struct Hotkey: Equatable {
    var keyCode: UInt16
    /// Only ⌘ ⌥ ⌃ ⇧. Empty for a lone modifier key.
    var modifiers: NSEvent.ModifierFlags

    static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Modifier key codes and the flag each one sets.
    private static let modifierKeys: [UInt16: NSEvent.ModifierFlags] = [
        54: .command, 55: .command, 56: .shift, 58: .option,
        59: .control, 60: .shift, 61: .option, 62: .control, 63: .function,
    ]

    /// Per-side bits in the raw flags, so Right ⌥ can be told from Left ⌥.
    private static let deviceMasks: [UInt16: UInt] = [
        54: 0x10, 55: 0x08, 56: 0x02, 58: 0x20, 59: 0x01, 60: 0x04, 61: 0x40, 62: 0x2000,
    ]

    private static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 36: "Return", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc", 117: "Fwd Delete",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    private static let modifierNames: [UInt16: String] = [
        54: "Right ⌘", 55: "Left ⌘", 56: "Left ⇧", 58: "Left ⌥", 59: "Left ⌃", 60: "Right ⇧", 61: "Right ⌥", 62: "Right ⌃", 63: "Fn",
    ]

    static let fn = Hotkey(keyCode: 63, modifiers: [])
    static let rightOption = Hotkey(keyCode: 61, modifiers: [])
    static let rightCommand = Hotkey(keyCode: 54, modifiers: [])
    static let controlSpace = Hotkey(keyCode: 49, modifiers: .control)

    /// The flag this key sets, if it is a lone modifier key.
    var modifierFlag: NSEvent.ModifierFlags? {
        modifiers.isEmpty ? Self.modifierKeys[keyCode] : nil
    }

    var isModifierOnly: Bool { modifierFlag != nil }

    /// Whether this modifier key is down, given the flags of a flagsChanged event.
    func isDown(in flags: NSEvent.ModifierFlags) -> Bool {
        if let mask = Self.deviceMasks[keyCode] { return flags.rawValue & mask != 0 }
        guard let flag = modifierFlag else { return false }
        return flags.contains(flag)
    }

    static func isModifierKey(_ keyCode: UInt16) -> Bool { modifierKeys[keyCode] != nil }

    var displayName: String {
        if isModifierOnly { return Self.modifierNames[keyCode] ?? "Key \(keyCode)" }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    /// Why a key combination can't be the hotkey, or nil if it can.
    static func problem(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        if modifiers.isEmpty && !functionKeys.contains(keyCode) {
            return "Add a modifier key (⌃ ⌥ ⇧ ⌘), or use a function key."
        }
        if modifiers == .command, [49, 48, 12, 13, 8, 9, 7, 6, 4, 46].contains(keyCode) {
            return "That shortcut is used by macOS and most apps."
        }
        return nil
    }
}

/// The choices shown in settings. `custom` uses the recorded key.
enum HotkeyPreset: String, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand, controlSpace, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fn: return "Fn (Globe)"
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .controlSpace: return "⌃Space"
        case .custom: return "Custom…"
        }
    }

    var hotkey: Hotkey? {
        switch self {
        case .fn: return .fn
        case .rightOption: return .rightOption
        case .rightCommand: return .rightCommand
        case .controlSpace: return .controlSpace
        case .custom: return nil
        }
    }
}
