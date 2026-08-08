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
    /// #238 — the attachment exists in the envelope but its body was never
    /// fetched from the server (`X-Apple-Content-Length` placeholder, empty
    /// body, no external cache file). Distinct from `attachmentNotFound` so
    /// the caller can act (open the message in Mail) instead of concluding
    /// the attachment doesn't exist.
    case attachmentNotDownloaded(name: String)

    /// A matching attachment was found but its decoded size exceeds the
    /// hard limit for in-memory extraction. Dispatchers fall through to
    /// the AppleScript path which can stream-write large files.
    case attachmentTooLarge(name: String, size: Int, limit: Int)

    /// An `account_name` (or `account_id`) was supplied to an account-scoped
    /// query but resolved to no configured account (#202). Surfaced instead of
    /// silently returning every account's data (the `list_mailboxes`
    /// return-all-unscoped latent bug).
    case accountNotResolvable(name: String)

    /// #344 — a `mailbox` filter resolved to no mailbox, but at least one
    /// **near-miss** exists: a mailbox that would have matched had the
    /// comparison ignored ASCII letter case or surrounding whitespace.
    ///
    /// The point is not the case rule; it is that an empty result stops being
    /// ambiguous. #317's whole subject was "a zero you cannot trust" — is the
    /// mailbox empty, is the name wrong, or is the filter too strict? Naming
    /// the candidate answers that without loosening the match (over-matching
    /// would return *another mailbox's mail*, which nobody notices).
    ///
    /// Only fires when a candidate exists; an unrelated name still yields an
    /// honest empty result, not an error.
    case mailboxNotResolvable(name: String, candidates: [String])

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
        case .attachmentNotDownloaded(let name):
            return "Attachment '\(name)' is not downloaded — it exists on the server but Mail has "
                + "not fetched its content (placeholder-only MIME part, no local cache). Open the "
                + "message in Mail (or set Settings > Accounts > Download Attachments: All) to "
                + "fetch it, then retry (#238)"
        case .attachmentTooLarge(let name, let size, let limit):
            return "Attachment '\(name)' is \(size) bytes, exceeds in-memory limit of \(limit) bytes"
        case .accountNotResolvable(let name):
            return "Account '\(name)' not found — use list_accounts to see configured accounts (pass account_id to disambiguate an email-form name)"
        case .mailboxNotResolvable(let name, let candidates):
            let suggestion = candidates.map { "'\($0)'" }.joined(separator: ", ")
            return "Mailbox '\(name)' matched no mailbox — did you mean \(suggestion)? "
                + "Mailbox names are matched exactly, component by component (the one "
                + "exception is a top-level INBOX, case-insensitive per RFC 3501 §5.1 — "
                + "a nested component named 'inbox' is NOT folded); use list_mailboxes to "
                + "see the exact names (#344)"
        }
    }
}
