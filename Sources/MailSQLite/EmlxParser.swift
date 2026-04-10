import Foundation

/// Parser for Apple Mail's .emlx file format.
/// Reads RFC 822 message data directly from .emlx files,
/// bypassing AppleScript for email content retrieval.
public enum EmlxParser {

    // MARK: - Path Resolution

    /// Compute the hash directory path for a given ROWID.
    ///
    /// Apple Mail V10 uses a **variable-depth** hash layout under each
    /// mailbox's `Data/` directory, driven by the decimal digits of
    /// `rowId / 1000`. The digits are emitted right-to-left:
    ///
    /// - rowId < 1000              → `""`         (file at `Data/Messages/`)
    /// - 1000 ≤ rowId < 10000      → `"d4"`       (`Data/d4/Messages/`)
    /// - 10000 ≤ rowId < 100000    → `"d4/d5"`    (`Data/d4/d5/Messages/`)
    /// - 100000 ≤ rowId < 1000000  → `"d4/d5/d6"` (`Data/d4/d5/d6/Messages/`)
    /// - …and so on for seven-digit ROWIDs and beyond.
    ///
    /// where `d4 = (rowId / 1000) % 10`,
    ///       `d5 = (rowId / 10000) % 10`,
    ///       `d6 = (rowId / 100000) % 10`, etc.
    ///
    /// Verified against **256,428 real .emlx files** (all four depth levels
    /// present in a production mailbox) on macOS Sequoia / Tahoe — see #9.
    /// Earlier versions of this resolver incorrectly assumed a fixed
    /// 3-level tree hashing ones/tens/hundreds of the ROWID, which silently
    /// matched only 61.5% of real files.
    ///
    /// Examples:
    ///   ROWID 218     → `""`        (depth 0)
    ///   ROWID 9865    → `"9"`       (depth 1)
    ///   ROWID 19926   → `"9/1"`     (depth 2)
    ///   ROWID 262653  → `"2/6/2"`   (depth 3)
    ///   ROWID 1234567 → `"4/3/2/1"` (depth 4)
    ///
    /// - Parameter rowId: The message ROWID from the Envelope Index.
    /// - Returns: A slash-separated path string (possibly empty).
    public static func hashDirectoryPath(rowId: Int) -> String {
        var n = rowId / 1000
        if n <= 0 {
            return ""
        }
        var parts: [String] = []
        while n > 0 {
            parts.append(String(n % 10))
            n /= 10
        }
        return parts.joined(separator: "/")
    }

    /// Resolve the filesystem path to an .emlx (or .partial.emlx) file
    /// for a given message ROWID and mailbox URL.
    ///
    /// Path pattern (variable depth — see `hashDirectoryPath`):
    /// `~/Library/Mail/V10/<account-uuid>/<mailbox-path>.mbox/<store-uuid>/Data/<hash>/Messages/<ROWID>.emlx`
    ///
    /// where `<hash>` is zero or more `/`-separated decimal digits.
    ///
    /// - Parameters:
    ///   - rowId: The message ROWID from the Envelope Index.
    ///   - mailboxURL: The mailbox URL string (e.g., `imap://UUID/[Gmail]/全部郵件`).
    /// - Returns: The filesystem path to the .emlx file, or `nil` if not found.
    public static func resolveEmlxPath(rowId: Int, mailboxURL: String) -> String? {
        guard let parsed = MailboxURL.decode(mailboxURL) else {
            return nil
        }

        let basePath = EnvelopeIndexReader.mailStoragePath
        let accountPath = "\(basePath)/\(parsed.accountUUID)"

        // Convert mailbox path segments to .mbox directories.
        // e.g., "[Gmail]/全部郵件" → "[Gmail].mbox/全部郵件.mbox"
        let segments = parsed.mailboxPath.split(separator: "/", omittingEmptySubsequences: true)
        let mboxPath = segments.map { "\($0).mbox" }.joined(separator: "/")
        let mailboxDir = "\(accountPath)/\(mboxPath)"

        // Find the store UUID subdirectory inside the .mbox directory.
        guard let storeUUID = findStoreUUID(in: mailboxDir) else {
            return nil
        }

        let hashDir = hashDirectoryPath(rowId: rowId)
        let dataPath = "\(mailboxDir)/\(storeUUID)/Data"
        let messagesDir: String
        if hashDir.isEmpty {
            // Depth 0: rowId < 1000 → file lives directly under Data/Messages/
            messagesDir = "\(dataPath)/Messages"
        } else {
            messagesDir = "\(dataPath)/\(hashDir)/Messages"
        }

        let fm = FileManager.default

        // Try the primary .emlx file first.
        let emlxPath = "\(messagesDir)/\(rowId).emlx"
        if fm.fileExists(atPath: emlxPath) {
            return emlxPath
        }

        // Fall back to .partial.emlx.
        let partialPath = "\(messagesDir)/\(rowId).partial.emlx"
        if fm.fileExists(atPath: partialPath) {
            return partialPath
        }

        return nil
    }

    // MARK: - Private Helpers

    /// Scan a .mbox directory for a UUID-formatted subdirectory (the store UUID).
    ///
    /// - Parameter mboxDir: Path to the .mbox directory.
    /// - Returns: The UUID directory name, or `nil` if none found.
    private static func findStoreUUID(in mboxDir: String) -> String? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: mboxDir) else {
            return nil
        }
        return contents.first { name in
            name.count == 36
            && name.split(separator: "-").count == 5
            && name.allSatisfy { $0.isHexDigit || $0 == "-" }
        }
    }

    // MARK: - Headers & Source

    /// Read raw headers from an .emlx file (everything before the blank line).
    public static func readHeaders(rowId: Int, mailboxURL: String) throws -> String {
        guard let path = resolveEmlxPath(rowId: rowId, mailboxURL: mailboxURL) else {
            throw MailSQLiteError.emlxNotFound(messageId: rowId, path: "Could not resolve path")
        }
        let fileData = try Data(contentsOf: URL(fileURLWithPath: path))
        let messageData = try EmlxFormat.extractMessageData(from: fileData)

        guard let splitOffset = RFC822Parser.headerBodySplitOffset(in: messageData) else {
            // No body separator — return entire message as headers
            return String(data: messageData, encoding: .utf8)
                ?? String(data: messageData, encoding: .ascii) ?? ""
        }

        let headerData = messageData[messageData.startIndex..<messageData.index(messageData.startIndex, offsetBy: splitOffset)]
        return String(data: headerData, encoding: .utf8)
            ?? String(data: headerData, encoding: .ascii) ?? ""
    }

    /// Read raw RFC 822 source from an .emlx file.
    public static func readSource(rowId: Int, mailboxURL: String) throws -> String {
        guard let path = resolveEmlxPath(rowId: rowId, mailboxURL: mailboxURL) else {
            throw MailSQLiteError.emlxNotFound(messageId: rowId, path: "Could not resolve path")
        }
        let fileData = try Data(contentsOf: URL(fileURLWithPath: path))
        let messageData = try EmlxFormat.extractMessageData(from: fileData)
        return String(data: messageData, encoding: .utf8)
            ?? String(data: messageData, encoding: .ascii) ?? ""
    }
}
