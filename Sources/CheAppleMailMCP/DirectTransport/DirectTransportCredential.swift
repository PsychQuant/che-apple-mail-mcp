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

    /// Creates or replaces the item for `address`. An existing item is updated in
    /// place, so a failure leaves the old password working rather than none.
    static func store(address: String, password: String) throws {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: address,
        ]
        let updated = SecItemUpdate(match as CFDictionary, [kSecValueData as String: Data(password.utf8)] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw Failure(description: "the existing keychain item for \(address) could not be replaced (OSStatus \(updated)); it is unchanged")
        }
        var add = match
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "che-apple-mail-mcp direct transport (\(address))"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Failure(description: "the keychain item for \(address) could not be stored (OSStatus \(status))")
        }
    }
}
