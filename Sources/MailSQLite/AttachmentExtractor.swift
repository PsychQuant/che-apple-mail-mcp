import Foundation

/// Direct-from-filesystem attachment extraction for Apple Mail `.emlx`
/// files. This is the fast path used by `save_attachment`, bypassing
/// AppleScript IPC with Mail.app.
///
/// The flow, once the `.emlx` path is resolved via
/// `EmlxParser.resolveEmlxPath` (which transparently honors the
/// `mailStoragePathOverride` test hook from `EnvelopeIndexReader`):
///
/// 1. Load file bytes with `Data(contentsOf:)` (in-memory).
/// 2. Strip the Apple wrapper via `EmlxFormat.extractMessageData`.
/// 3. Split RFC 822 headers from body via `RFC822Parser.headerBodySplitOffset`.
/// 4. Walk the full MIME tree via `MIMEParser.parseAllParts` (non-lossy).
/// 5. Find the **first** part whose filename matches the requested
///    `attachmentName` (first-match semantics — see design.md).
/// 6. Write `decodedData.write(to: destination)`.
///
/// The size limit for in-memory extraction is 100 MB per part. Anything
/// larger throws `MailSQLiteError.attachmentTooLarge`, which the
/// dispatcher catches and falls through to the AppleScript path. This
/// hybrid strategy avoids the complexity of a streaming rewrite while
/// keeping the fast path safe for typical email workloads.
extension EmlxParser {

    /// Hard limit (in bytes) for a single attachment part on the fast
    /// path. Parts larger than this throw `attachmentTooLarge` and are
    /// handled by the AppleScript fallback.
    public static let attachmentInMemoryLimit = 100 * 1024 * 1024  // 100 MB

    /// Save an attachment from the referenced message to disk, using the
    /// SQLite + `.emlx` fast path.
    ///
    /// - Parameters:
    ///   - rowId: The message ROWID from the Envelope Index.
    ///   - mailboxURL: The raw mailbox URL from the database.
    ///   - attachmentName: The filename to match. Matching is
    ///     case-sensitive and compares against both
    ///     `Content-Disposition: filename` (with RFC 2231/5987 decoding)
    ///     and the legacy `Content-Type: name` parameter.
    ///   - destination: File URL to write to. Parent directory MUST
    ///     already exist.
    /// - Throws:
    ///   - `MailSQLiteError.emlxNotFound` if the `.emlx` cannot be
    ///     located
    ///   - `MailSQLiteError.emlxParseFailed` if the envelope cannot be
    ///     parsed
    ///   - `MailSQLiteError.attachmentNotFound` if no MIME part matches
    ///     the filename
    ///   - `MailSQLiteError.attachmentTooLarge` if the matched part's
    ///     decoded size exceeds `attachmentInMemoryLimit`
    ///   - Foundation file-IO errors on write failure
    public static func saveAttachment(
        rowId: Int,
        mailboxURL: String,
        attachmentName: String,
        destination: URL
    ) throws {
        // Step 1: resolve .emlx path. Reuses mailStoragePathOverride
        // transparently (task 4.6).
        guard let path = resolveEmlxPath(rowId: rowId, mailboxURL: mailboxURL) else {
            throw MailSQLiteError.emlxNotFound(
                messageId: rowId,
                path: "Could not resolve .emlx path for message \(rowId)"
            )
        }

        // Step 2: load file and strip Apple wrapper.
        let fileData = try Data(contentsOf: URL(fileURLWithPath: path))
        let messageData = try EmlxFormat.extractMessageData(from: fileData)

        // Step 3: split headers / body.
        let headers = RFC822Parser.parseHeaders(from: messageData)
        guard let bodyOffset = RFC822Parser.headerBodySplitOffset(in: messageData) else {
            throw MailSQLiteError.emlxParseFailed(
                "No header/body split found in message \(rowId)"
            )
        }
        let bodyData = Data(messageData[bodyOffset...])

        // Step 4: walk all parts non-lossy.
        let parts = MIMEParser.parseAllParts(bodyData, headers: headers)

        // Step 5: first-match by filename, checking both
        // Content-Disposition.filename and Content-Type.name. Matching is
        // exact and case-sensitive — users pass what list_attachments
        // returned, which is itself the SQLite-stored name.
        guard let part = parts.first(where: { matchesAttachmentName($0, attachmentName) }) else {
            throw MailSQLiteError.attachmentNotFound(name: attachmentName)
        }

        // Size guard — large parts fall through to AppleScript streaming.
        let size = part.decodedData.count
        if size > attachmentInMemoryLimit {
            throw MailSQLiteError.attachmentTooLarge(
                name: attachmentName,
                size: size,
                limit: attachmentInMemoryLimit
            )
        }

        // Step 6: write decoded bytes. Use atomic write so partial files
        // never appear on disk on failure.
        try part.decodedData.write(to: destination, options: .atomic)
    }

    /// First-match predicate: part's resolved filename equals request, or
    /// the Content-Type name parameter equals request. Both comparisons
    /// are case-sensitive to match how `list_attachments` surfaces names.
    private static func matchesAttachmentName(
        _ part: MIMEPart,
        _ request: String
    ) -> Bool {
        if let filename = part.filename, filename == request {
            return true
        }
        if let name = part.contentTypeParams["name"], name == request {
            return true
        }
        return false
    }
}
