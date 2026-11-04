import Foundation
import Security

/// One-time move of everything the app kept under its old name, Flowstate,
/// to the FnSpeak locations: the data folder (notes, history, models), the
/// settings domain and the Keychain items. Runs before anything reads
/// preferences, and is a no-op once the new locations exist.
enum LegacyMigration {
    private static let oldName = "Flowstate"
    private static let newName = "FnSpeak"
    private static let oldDomain = "dev.flowstate.Flowstate"
    private static let oldService = "dev.flowstate.Flowstate.api-keys"
    private static let newService = "com.fnspeak.FnSpeak.api-keys"
    private static let doneKey = "migratedFromFlowstate"

    static func run() {
        migrateDataFolder()
        migrateDefaults()
    }

    /// ~/Library/Application Support/Flowstate → …/FnSpeak, only when the
    /// new folder doesn't exist yet. The models alone are a few GB, so this
    /// is a rename, not a copy.
    private static func migrateDataFolder() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent(oldName, isDirectory: true)
        let new = base.appendingPathComponent(newName, isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do {
            try fm.moveItem(at: old, to: new)
        } catch {
            NSLog("FnSpeak: could not move \(old.path) to \(new.path): \(error)")
        }
    }

    /// Settings lived in the old bundle id's defaults domain. Copy any key
    /// the new domain doesn't have, then bring the Keychain items over.
    private static func migrateDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            // The hosted cleanup provider was named after the app.
            if key == "cloudProvider", let s = value as? String, s == "flowstate" {
                defaults.set("fnspeak", forKey: key)
            } else {
                defaults.set(value, forKey: key)
            }
        }
        for account in ["anthropic", "groq", "custom", "flowstate", "webhook-secret"] {
            guard let value = keychainRead(service: oldService, account: account) else { continue }
            let newAccount = account == "flowstate" ? "fnspeak" : account
            if keychainRead(service: newService, account: newAccount) == nil {
                keychainWrite(value, service: newService, account: newAccount)
            }
            keychainDelete(service: oldService, account: account)
        }
    }

    private static func keychainRead(service: String, account: String) -> String? {
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

    private static func keychainWrite(_ value: String, service: String, account: String) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func keychainDelete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
