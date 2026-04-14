import Foundation

/// Builds account UUID → display name mapping from filesystem sources.
/// Reads AccountsMap.plist to avoid any AppleScript dependency.
public enum AccountMapper {

    private static let accountsMapPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Mail/V10/MailData/Signatures/AccountsMap.plist"
    }()

    /// Build UUID → account name mapping from AccountsMap.plist.
    ///
    /// The plist maps each UUID to a dictionary with an `AccountURL` key
    /// containing the account's email (percent-encoded in the URL authority).
    /// For example: `imap://kiki830621%40gmail.com/` → `kiki830621@gmail.com`
    ///
    /// - Parameter path: Override path for testing. Defaults to the standard location.
    /// - Returns: Dictionary mapping account UUIDs to email addresses.
    public static func buildMapping(path: String? = nil) -> [String: String] {
        let filePath = path ?? accountsMapPath
        guard let data = FileManager.default.contents(atPath: filePath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any] else {
            return [:]
        }

        var mapping: [String: String] = [:]
        for (uuid, value) in plist {
            guard let dict = value as? [String: Any],
                  let accountURL = dict["AccountURL"] as? String else {
                continue
            }
            if let email = extractEmail(from: accountURL) {
                mapping[uuid] = email
            } else {
                // AccountURL is opaque (e.g., EWS/Exchange store URL). Fall
                // back to the UUID itself rather than leaking the raw URL
                // as a "display name" — see #9. Downstream callers already
                // use `accountName(for:)`, which returns the UUID when no
                // mapping exists, so behavior is consistent either way.
                mapping[uuid] = uuid
            }
        }
        return mapping
    }

    /// Extract the email address from an AccountURL string.
    ///
    /// Formats:
    /// - `imap://user%40domain/` → `user@domain`
    /// - `ews://AAMkAGE5...==/` → returns nil (EWS uses opaque identifiers)
    static func extractEmail(from accountURL: String) -> String? {
        // Remove scheme (imap://, ews://, etc.)
        guard let schemeEnd = accountURL.range(of: "://") else { return nil }
        let authority = accountURL[schemeEnd.upperBound...]

        // Remove trailing path (everything after first /)
        let host: Substring
        if let slashIdx = authority.firstIndex(of: "/") {
            host = authority[authority.startIndex..<slashIdx]
        } else {
            host = authority
        }

        // Percent-decode
        guard let decoded = String(host).removingPercentEncoding else {
            return String(host)
        }

        // Only return if it looks like an email (contains @)
        if decoded.contains("@") {
            return decoded
        }
        return nil
    }
}
