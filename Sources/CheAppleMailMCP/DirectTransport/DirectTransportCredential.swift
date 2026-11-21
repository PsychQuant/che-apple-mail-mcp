import Foundation
import Security

/// The password of a direct-transport account (#742): a generic-password
/// keychain item that this binary creates, never one that belongs to Mail.
///
/// Only the command-line mode `--direct-transport-set-credential` writes it,
/// from standard input; no MCP tool can create, change or reveal it. The value
/// is read at call time and handed to the connection, and goes nowhere else.
enum DirectTransportCredential {
    static let service = "che-apple-mail-mcp.direct-transport"

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The password for `address`, or nil when no item exists.
    static func read(address: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: address,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            throw Failure(description: "the keychain item for \(address) could not be read (OSStatus \(status))")
        }
        return text
    }

    /// Creates or replaces the item for `address`.
    ///
    /// The item is always one this binary added, so its access list trusts only
    /// this binary. An existing item is never updated in place: another program
    /// could have created an item under this service whose access list lets it
    /// read the value, and writing the password into it would hand it over. So a
    /// duplicate is deleted (which fails for an item this binary may not touch)
    /// and the item added again. If that second add fails, the old item is gone:
    /// the message says so, and the person running the command runs it again.
    static func store(address: String, password: String) throws {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: address,
        ]
        var add = match
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "che-apple-mail-mcp direct transport (\(address))"
        let first = SecItemAdd(add as CFDictionary, nil)
        if first == errSecSuccess { return }
        guard first == errSecDuplicateItem else {
            throw Failure(description: "the keychain item for \(address) could not be stored (OSStatus \(first))")
        }
        let deleted = SecItemDelete(match as CFDictionary)
        guard deleted == errSecSuccess else {
            throw Failure(description: "an existing keychain item for \(address) could not be removed (OSStatus \(deleted)); it is unchanged and nothing was stored. Delete it in Keychain Access if this binary did not create it")
        }
        let second = SecItemAdd(add as CFDictionary, nil)
        guard second == errSecSuccess else {
            throw Failure(description: "the old keychain item for \(address) was removed but the new one could not be stored (OSStatus \(second)); run the command again")
        }
    }
}
