import Foundation

/// Errors from the MailSQLite module.
public enum MailSQLiteError: Error, LocalizedError {
    case databaseNotAccessible(String)
    case queryFailed(String)
    case emlxNotFound(messageId: Int, path: String)
    case emlxParseFailed(String)
    case batchSizeExceeded(limit: Int)

    /// No MIME part with the requested filename was found inside the
    /// resolved .emlx. Dispatchers use this as a signal to fall through
    /// to the AppleScript path (the SQLite metadata and the on-disk
    /// .emlx may be out of sync).
    case attachmentNotFound(name: String)

    /// A matching attachment was found but its decoded size exceeds the
    /// hard limit for in-memory extraction. Dispatchers fall through to
    /// the AppleScript path which can stream-write large files.
    case attachmentTooLarge(name: String, size: Int, limit: Int)

    /// An `account_name` (or `account_id`) was supplied to an account-scoped
    /// query but resolved to no configured account (#202). Surfaced instead of
    /// silently returning every account's data (the `list_mailboxes`
    /// return-all-unscoped latent bug).
    case accountNotResolvable(name: String)

    public var errorDescription: String? {
        switch self {
        case .databaseNotAccessible(let msg):
            return "Database not accessible: \(msg)"
        case .queryFailed(let msg):
            return "Query failed: \(msg)"
        case .emlxNotFound(let id, let path):
            return "Message \(id) .emlx not found at \(path)"
        case .emlxParseFailed(let msg):
            return "Failed to parse .emlx: \(msg)"
        case .batchSizeExceeded(let limit):
            return "Batch size exceeds maximum of \(limit) items"
        case .attachmentNotFound(let name):
            return "Attachment '\(name)' not found in message MIME parts"
        case .attachmentTooLarge(let name, let size, let limit):
            return "Attachment '\(name)' is \(size) bytes, exceeds in-memory limit of \(limit) bytes"
        case .accountNotResolvable(let name):
            return "Account '\(name)' not found — use list_accounts to see configured accounts (pass account_id to disambiguate an email-form name)"
        }
    }
}
