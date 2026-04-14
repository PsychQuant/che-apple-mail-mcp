import Foundation

/// Structured account info returned by `list_accounts`.
///
/// Fields map to Apple Mail's AppleScript `account` class attributes:
/// - `name`: the `name` attribute (for EWS this is `ews://.../` — **not** usable as
///   an `account "..."` AppleScript reference).
/// - `userName`: the `user name` attribute (typically the email address for EWS).
/// - `id`: the `id` attribute (account UUID).
/// - `emailAddresses`: the `email addresses` attribute (list of addresses).
/// - `displayName`: the canonical identifier to pass back to `get_email` etc.
///   Rule: `userName ?? emailAddresses.first ?? name`.
/// - `enabled`: whether the account is enabled in Mail.app.
public struct AccountInfo: Sendable, Equatable {
    public let name: String
    public let userName: String?
    public let id: String
    public let emailAddresses: [String]
    public let displayName: String
    public let enabled: Bool

    public init(
        name: String,
        userName: String?,
        id: String,
        emailAddresses: [String],
        enabled: Bool
    ) {
        self.name = name
        self.userName = userName
        self.id = id
        self.emailAddresses = emailAddresses
        self.enabled = enabled
        self.displayName = AccountInfo.computeDisplayName(
            name: name,
            userName: userName,
            emailAddresses: emailAddresses
        )
    }

    public static func computeDisplayName(
        name: String,
        userName: String?,
        emailAddresses: [String]
    ) -> String {
        if let userName = userName, !userName.isEmpty {
            return userName
        }
        if let first = emailAddresses.first, !first.isEmpty {
            return first
        }
        return name
    }

    /// JSON-serializable dictionary for MCP response.
    public func asDictionary() -> [String: Any] {
        [
            "name": name,
            "user_name": userName as Any,
            "id": id,
            "email_addresses": emailAddresses,
            "display_name": displayName,
            "enabled": enabled
        ]
    }
}

/// Parses the raw string output of Apple Mail's `list_accounts` AppleScript.
///
/// The AppleScript emits one record per account, using:
/// - U+001E (RECORD SEPARATOR) between account records
/// - U+001F (UNIT SEPARATOR) between fields within a record
/// - U+001D (GROUP SEPARATOR) between items in the `email addresses` list
///
/// Field order per record: `name ␟ user_name ␟ id ␟ email_addresses ␟ enabled`
///
/// These control characters are used because they are guaranteed not to appear
/// in legitimate account metadata (name, email, UUID) and avoid the quoting
/// headaches of `&` / `,` / newline as separators.
public enum AccountsScriptParser {

    /// Field count per record (name, user_name, id, email_addresses, enabled).
    static let fieldCount = 5

    static let recordSeparator: Character = "\u{001E}"
    static let unitSeparator: Character = "\u{001F}"
    static let groupSeparator: Character = "\u{001D}"

    /// Parse the raw string into a list of `AccountInfo`.
    ///
    /// Malformed records (wrong field count, empty id) are skipped silently
    /// rather than failing the whole call — if Mail.app returns partial data
    /// we still want the accounts we can parse.
    public static func parse(_ raw: String) -> [AccountInfo] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return trimmed
            .split(separator: recordSeparator, omittingEmptySubsequences: true)
            .compactMap { parseRecord(String($0)) }
    }

    private static func parseRecord(_ record: String) -> AccountInfo? {
        let fields = record.split(
            separator: unitSeparator,
            maxSplits: fieldCount - 1,
            omittingEmptySubsequences: false
        ).map(String.init)

        guard fields.count == fieldCount else { return nil }

        let name = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let userNameRaw = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let userName: String? = userNameRaw.isEmpty ? nil : userNameRaw
        let id = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let emailsField = fields[3]
        let enabledRaw = fields[4].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !id.isEmpty, !name.isEmpty else { return nil }

        let emailAddresses = emailsField
            .split(separator: groupSeparator, omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let enabled = (enabledRaw == "true")

        return AccountInfo(
            name: name,
            userName: userName,
            id: id,
            emailAddresses: emailAddresses,
            enabled: enabled
        )
    }
}
