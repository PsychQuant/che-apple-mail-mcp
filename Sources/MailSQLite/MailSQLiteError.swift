import Foundation

/// Errors from the MailSQLite module.
public enum MailSQLiteError: Error, LocalizedError {
    case databaseNotAccessible(String)
    case queryFailed(String)
    case emlxNotFound(messageId: Int, path: String)
    case emlxParseFailed(String)
    case batchSizeExceeded(limit: Int)

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
        }
    }
}
