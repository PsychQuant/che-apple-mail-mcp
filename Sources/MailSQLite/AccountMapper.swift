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
    /// For example: `imap://alice%40example.com/` → `alice@example.com`
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

    /// Reverse lookup: all account UUIDs whose AccountsMap email matches the
    /// given address (#173).
    ///
    /// SQLite-path tools emit AccountsMap emails as `account_name`, but
    /// Mail's AppleScript `account "<name>"` selector matches the account
    /// DESCRIPTION (e.g. "Google") — feeding the email back fails with
    /// -1728. Callers use this lookup to upgrade an email-form account_name
    /// to the collision-free `account id "<UUID>"` selector.
    ///
    /// The same email can map to MULTIPLE UUIDs (e.g. an iCloud catch-all
    /// and a Google account both presenting the same address), so the full
    /// sorted list is returned and the caller decides how to handle
    /// ambiguity — auto-picking would silently target the wrong account.
    ///
    /// Comparison is case-insensitive and only considers email-shaped
    /// mapping values (containing `@`) — EWS entries store the UUID itself
    /// as a fallback value (#9) and must never match an email query.
    ///
    /// - Parameter path: Override path for testing. Defaults to the standard location.
    /// - Returns: Sorted array of matching account UUIDs (empty when none).
    public static func uuids(forEmail email: String, path: String? = nil) -> [String] {
        let needle = email.lowercased()
        return buildMapping(path: path)
            .filter { $0.value.contains("@") && $0.value.lowercased() == needle }
            .map(\.key)
            .sorted()
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
