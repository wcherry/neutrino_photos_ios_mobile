import Foundation
import Security

// MARK: - KeychainService

/// Thin wrapper over the generic-password keychain, used for auth tokens and the encryption
/// identity key.
///
/// Every item is written with ``accessibility``. See the note there — it is the one attribute in
/// this file with a consequence worth understanding.
enum KeychainService {

    // MARK: - Accessibility

    /// When a stored secret is readable, and where it may travel.
    ///
    /// *AfterFirstUnlock*: readable once the device has been unlocked at least since boot, and from
    /// then on even while the screen is locked. That is what an upload running in the background
    /// needs — it has to reach the account's public key to seal a file key, and a phone in a pocket
    /// is a locked phone. `WhenUnlocked` would mean backup silently stops whenever the screen
    /// locks, and nobody would find out until they looked.
    ///
    /// *ThisDeviceOnly*: excluded from iCloud Keychain and from encrypted backups, so neither the
    /// refresh token nor the identity private key can be restored onto a device the user did not
    /// unlock it on. The cost is that a new phone has to unlock the vault again, which is a password
    /// the user already has; the alternative is an end-to-end encryption key that syncs itself to
    /// Apple, which is not end-to-end encryption.
    ///
    /// The trade is therefore between "before first unlock" and "after a reboot". Nothing this app
    /// does runs before first unlock: `BGTaskScheduler` does not fire on a device that has not been
    /// unlocked since boot, so there is no window this closes.
    static let accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    // MARK: - Save

    /// Saves or updates a string value for the given key. Returns true on success.
    @discardableResult
    static func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData: data,
            kSecAttrAccessible: accessibility
        ]

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }

        if addStatus == errSecDuplicateItem {
            let searchQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: key
            ]
            // Re-stated on update as well as on add: an item written by an older build with a
            // different accessibility keeps it forever otherwise, because `SecItemUpdate` changes
            // only the attributes it is handed.
            let updateAttributes: [CFString: Any] = [
                kSecValueData: data,
                kSecAttrAccessible: accessibility
            ]
            let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
            return updateStatus == errSecSuccess
        }

        return false
    }

    // MARK: - Load

    /// Loads a string value for the given key, or nil when absent.
    static func load(forKey key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The accessibility attribute an item was actually stored with, or nil when there is no such
    /// item. Exists so a test can assert the promise ``accessibility`` makes, rather than trusting
    /// that every write site remembered to pass it.
    static func accessibility(forKey key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [CFString: Any] else { return nil }
        return attributes[kSecAttrAccessible] as? String
    }

    // MARK: - Delete

    /// Deletes the item for the given key. Returns true if an item was found and deleted.
    @discardableResult
    static func delete(forKey key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
