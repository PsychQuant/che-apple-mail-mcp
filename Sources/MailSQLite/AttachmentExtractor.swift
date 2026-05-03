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

        // Step 5b (#66): if the matched MIME part has no inline body, the
        // attachment binary lives in Apple Mail's sibling
        // `Attachments/<rowId>/<part_id>/<filename>` cache. This happens
        // for `.partial.emlx` messages (Mail.app extracts attachments to
        // the external folder after IMAP fetch and strips the base64 body
        // from the on-disk envelope to save space). Without this lookup
        // we would silently `data.write(...)` an empty `Data()` and lie
        // about success.
        if part.decodedData.isEmpty {
            if let externalURL = externalAttachmentURL(
                emlxPath: path,
                rowId: rowId,
                attachmentName: attachmentName
            ) {
                let externalBytes = try Data(contentsOf: externalURL)
                if externalBytes.count > attachmentInMemoryLimit {
                    throw MailSQLiteError.attachmentTooLarge(
                        name: attachmentName,
                        size: externalBytes.count,
                        limit: attachmentInMemoryLimit
                    )
                }
                try externalBytes.write(to: destination, options: .atomic)
                return
            }
            // Inline body empty AND no external file — treat as missing
            // so the AppleScript fallback can have a turn (or surface the
            // failure to the caller). NEVER write a 0-byte file: that's
            // the silent-failure mode bug #66 was filed for.
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

    /// Look up the externalised attachment binary that Apple Mail stores
    /// alongside a `.partial.emlx` message. Layout:
    ///
    /// ```
    /// <hashDir>/Messages/<rowId>.partial.emlx          ← envelope (no body)
    /// <hashDir>/Attachments/<rowId>/<part_id>/<filename>  ← real bytes
    /// ```
    ///
    /// The `<part_id>` subfolder is opaque to us (Apple Mail picks it
    /// based on the MIME tree at extraction time), so we walk every
    /// subdirectory and return the first match by filename.
    ///
    /// Returns `nil` if the `Attachments/<rowId>/` directory doesn't exist
    /// or contains no file matching `attachmentName`.
    private static func externalAttachmentURL(
        emlxPath: String,
        rowId: Int,
        attachmentName: String
    ) -> URL? {
        // emlxPath is `<hashDir>/Messages/<rowId>.{partial.,}emlx`. Walk up
        // two levels to get the hash dir, then descend into Attachments.
        let messagesDir = URL(fileURLWithPath: emlxPath).deletingLastPathComponent()
        let hashDir = messagesDir.deletingLastPathComponent()
        let attachmentsRoot = hashDir
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("\(rowId)", isDirectory: true)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: attachmentsRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        // Each subdirectory is one MIME part; the file name inside should
        // match `attachmentName` byte-for-byte.
        guard let partIds = try? fm.contentsOfDirectory(atPath: attachmentsRoot.path) else {
            return nil
        }
        for partId in partIds {
            let candidate = attachmentsRoot
                .appendingPathComponent(partId, isDirectory: true)
                .appendingPathComponent(attachmentName)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
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

    /// Return the union of attachment names actually present in the
    /// `.emlx` envelope — both `Content-Disposition: filename` (RFC
    /// 2231/5987 decoded) and the legacy `Content-Type: name` parameter.
    ///
    /// Useful for cross-validating SQLite's cached `attachments` table
    /// against the on-disk message body. SQLite metadata can drift from
    /// reality (Sent message after IMAP binary strip, lazy-loaded
    /// IMAP message that never received its body) and surface
    /// "attachments" that `saveAttachment` cannot actually extract — see
    /// issue #24.
    ///
    /// Internally walks the MIME tree via
    /// `MIMEParser.enumerateAttachmentNames` — a names-only traversal that
    /// **does not** decode transfer-encoded body bytes. This makes the
    /// memory + CPU cost O(message structure size), independent of total
    /// attachment payload size, which is critical when a `list_attachments`
    /// caller doesn't actually need the binary (see verify finding for #24:
    /// `parseAllParts` would eager-decode every base64 attachment just to
    /// read its filename).
    ///
    /// - Throws:
    ///   - `MailSQLiteError.emlxNotFound` if the `.emlx` path cannot be
    ///     resolved
    ///   - `MailSQLiteError.emlxParseFailed` if the envelope cannot be
    ///     parsed
    ///   - Foundation file-IO errors on read failure
    public static func attachmentNames(
        rowId: Int,
        mailboxURL: String
    ) throws -> Set<String> {
        guard let path = resolveEmlxPath(rowId: rowId, mailboxURL: mailboxURL) else {
            throw MailSQLiteError.emlxNotFound(
                messageId: rowId,
                path: "Could not resolve .emlx path for message \(rowId)"
            )
        }
        let fileData = try Data(contentsOf: URL(fileURLWithPath: path))
        let messageData = try EmlxFormat.extractMessageData(from: fileData)
        let headers = RFC822Parser.parseHeaders(from: messageData)
        guard let bodyOffset = RFC822Parser.headerBodySplitOffset(in: messageData) else {
            throw MailSQLiteError.emlxParseFailed(
                "No header/body split found in message \(rowId)"
            )
        }
        let bodyData = Data(messageData[bodyOffset...])
        return MIMEParser.enumerateAttachmentNames(bodyData, headers: headers)
    }
}
