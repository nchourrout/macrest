import Foundation
import Security

/// The repository password, kept in the login keychain as well as in
/// Backrest's config: Backrest needs it in its config to run, the keychain
/// copy is the one that survives a lost config and syncs nowhere unasked.
enum Keychain {
    static let service = "MacRest restic repository"

    static func save(password: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "MacRest: \(account)"
        SecItemAdd(add as CFDictionary, nil)
    }
}
