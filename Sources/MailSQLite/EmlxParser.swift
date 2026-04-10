import Foundation

/// Parser for Apple Mail's .emlx file format.
/// Reads RFC 822 message data directly from .emlx files,
/// bypassing AppleScript for email content retrieval.
public enum EmlxParser {

    // MARK: - Path Resolution

    /// Compute the hash directory path for a given ROWID.
    ///
    /// Apple Mail V10 stores .emlx files in a 3-level directory tree whose
    /// components are the thousands, tenthousands, and hundredthousands digits
    /// of the ROWID (not ones/tens/hundreds as earlier versions of this
    /// resolver incorrectly assumed — see #9):
    /// - d1 = (rowId / 1000) % 10
    /// - d2 = (rowId / 10000) % 10
    /// - d3 = (rowId / 100000) % 10
    ///
    /// Examples verified against real mailboxes on macOS Sequoia / Tahoe:
    ///   ROWID 262653 → `2/6/2`
    ///   ROWID 267943 → `7/6/2`
    ///   ROWID 999    → `0/0/0`
    ///
    /// - Parameter rowId: The message ROWID from the Envelope Index.
    /// - Returns: A relative path string like `"2/6/2"`.
    public static func hashDirectoryPath(rowId: Int) -> String {
        let d1 = (rowId / 1000) % 10      // thousands
        let d2 = (rowId / 10000) % 10     // tenthousands
        let d3 = (rowId / 100000) % 10    // hundredthousands
        return "\(d1)/\(d2)/\(d3)"
    }

    /// Resolve the filesystem path to an .emlx (or .partial.emlx) file
    /// for a given message ROWID and mailbox URL.
    ///
    /// Path pattern:
    /// `~/Library/Mail/V10/<account-uuid>/<mailbox-path>.mbox/<store-uuid>/Data/<d1>/<d2>/<d3>/Messages/<ROWID>.emlx`
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
        let messagesDir = "\(mailboxDir)/\(storeUUID)/Data/\(hashDir)/Messages"

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
