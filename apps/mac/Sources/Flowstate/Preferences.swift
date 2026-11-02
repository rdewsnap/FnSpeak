import AppKit
import Foundation
import Security

/// User settings. Everything except API keys lives in UserDefaults; keys go
/// in the Keychain.
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    enum CloudProviderChoice: String, CaseIterable, Identifiable {
        case anthropic, groq, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .anthropic: return "Anthropic (Claude)"
            case .groq: return "Groq"
            case .custom: return "Other OpenAI-compatible"
            }
        }
    }

    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }
    /// `local`, `cloud`, `filterOnly` or `raw`.
    @Published var mode: String { didSet { defaults.set(mode, forKey: "mode") } }
    /// `whisper` or `parakeet`.
    @Published var speechEngine: String { didSet { defaults.set(speechEngine, forKey: "speechEngine") } }
    @Published var cloudProvider: CloudProviderChoice { didSet { defaults.set(cloudProvider.rawValue, forKey: "cloudProvider") } }
    @Published var cloudModel: String { didSet { defaults.set(cloudModel, forKey: "cloudModel") } }
    @Published var cloudLightModel: String { didSet { defaults.set(cloudLightModel, forKey: "cloudLightModel") } }
    @Published var customBaseURL: String { didSet { defaults.set(customBaseURL, forKey: "customBaseURL") } }
    @Published var projectsFolder: String { didSet { defaults.set(projectsFolder, forKey: "projectsFolder") } }
    @Published var indexContacts: Bool { didSet { defaults.set(indexContacts, forKey: "indexContacts") } }
    @Published var indexCalendar: Bool { didSet { defaults.set(indexCalendar, forKey: "indexCalendar") } }
    @Published var historyDays: Int { didSet { defaults.set(historyDays, forKey: "historyDays") } }
    /// Watch for the user fixing dictated words and learn the spelling.
    @Published var learnFromCorrections: Bool { didSet { defaults.set(learnFromCorrections, forKey: "learnFromCorrections") } }
    /// Bundle id → `ax` or `type`, for apps where pasting doesn't work.
    @Published var insertionOverrides: [String: String] { didSet { defaults.set(insertionOverrides, forKey: "insertionOverrides") } }

    // MARK: General

    @Published var showInMenuBar: Bool { didSet { defaults.set(showInMenuBar, forKey: "showInMenuBar") } }
    @Published var showInDock: Bool { didSet { defaults.set(showInDock, forKey: "showInDock") } }
    @Published var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: "soundsEnabled") } }

    // MARK: Dictation

    /// A `HotkeyPreset` raw value.
    @Published var hotkeyPreset: String { didSet { defaults.set(hotkeyPreset, forKey: "hotkeyPreset") } }
    @Published var customHotkeyKeyCode: Int { didSet { defaults.set(customHotkeyKeyCode, forKey: "customHotkeyKeyCode") } }
    @Published var customHotkeyModifiers: Int { didSet { defaults.set(customHotkeyModifiers, forKey: "customHotkeyModifiers") } }
    /// `hold`, `toggle` or `both` (hold, or double-tap for hands-free).
    @Published var triggerStyle: String { didSet { defaults.set(triggerStyle, forKey: "triggerStyle") } }
    @Published var escapeCancels: Bool { didSet { defaults.set(escapeCancels, forKey: "escapeCancels") } }

    private init() {
        onboarded = defaults.bool(forKey: "onboarded")
        mode = defaults.string(forKey: "mode") ?? "filterOnly"
        speechEngine = defaults.string(forKey: "speechEngine") ?? "whisper"
        cloudProvider = CloudProviderChoice(rawValue: defaults.string(forKey: "cloudProvider") ?? "") ?? .groq
        cloudModel = defaults.string(forKey: "cloudModel") ?? "meta-llama/llama-4-scout-17b-16e-instruct"
        cloudLightModel = defaults.string(forKey: "cloudLightModel") ?? "llama-3.1-8b-instant"
        customBaseURL = defaults.string(forKey: "customBaseURL") ?? "http://localhost:11434/v1"
        projectsFolder = defaults.string(forKey: "projectsFolder")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects").path
        indexContacts = defaults.object(forKey: "indexContacts") as? Bool ?? true
        indexCalendar = defaults.object(forKey: "indexCalendar") as? Bool ?? true
        historyDays = defaults.object(forKey: "historyDays") as? Int ?? 30
        learnFromCorrections = defaults.object(forKey: "learnFromCorrections") as? Bool ?? true
        insertionOverrides = defaults.dictionary(forKey: "insertionOverrides") as? [String: String] ?? [:]
        showInMenuBar = defaults.object(forKey: "showInMenuBar") as? Bool ?? true
        showInDock = defaults.object(forKey: "showInDock") as? Bool ?? false
        soundsEnabled = defaults.object(forKey: "soundsEnabled") as? Bool ?? false
        hotkeyPreset = defaults.string(forKey: "hotkeyPreset") ?? HotkeyPreset.fn.rawValue
        customHotkeyKeyCode = defaults.object(forKey: "customHotkeyKeyCode") as? Int ?? 49
        customHotkeyModifiers = defaults.object(forKey: "customHotkeyModifiers") as? Int
            ?? Int(NSEvent.ModifierFlags([.control, .option]).rawValue)
        triggerStyle = defaults.string(forKey: "triggerStyle") ?? "both"
        escapeCancels = defaults.object(forKey: "escapeCancels") as? Bool ?? true
    }

    var customHotkey: Hotkey {
        get {
            Hotkey(keyCode: UInt16(clamping: customHotkeyKeyCode),
                   modifiers: NSEvent.ModifierFlags(rawValue: UInt(clamping: customHotkeyModifiers)).intersection(Hotkey.relevant))
        }
        set {
            customHotkeyKeyCode = Int(newValue.keyCode)
            customHotkeyModifiers = Int(newValue.modifiers.rawValue)
        }
    }

    /// The key that starts dictation.
    var hotkey: Hotkey {
        (HotkeyPreset(rawValue: hotkeyPreset) ?? .fn).hotkey ?? customHotkey
    }

    /// Sensible model defaults when switching providers.
    func applyProviderDefaults() {
        switch cloudProvider {
        case .anthropic:
            cloudModel = "claude-haiku-5-5"
            cloudLightModel = "claude-haiku-5-5"
        case .groq:
            cloudModel = "meta-llama/llama-4-scout-17b-16e-instruct"
            cloudLightModel = "llama-3.1-8b-instant"
        case .custom:
            break
        }
    }

    var apiKey: String? {
        get { Keychain.read(account: cloudProvider.rawValue) }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.write(newValue, account: cloudProvider.rawValue)
            } else {
                Keychain.delete(account: cloudProvider.rawValue)
            }
            objectWillChange.send()
        }
    }
}

enum Keychain {
    private static let service = "dev.flowstate.Flowstate.api-keys"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        delete(account: account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
