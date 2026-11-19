import Foundation

extension EmlxParser {

    /// The Message-ID of a whole RFC 822 message: what `readEmail` reports as `messageId`, so
    /// `get_email`, `get_emails_batch`, the batch export and `search_emails` (#682) agree.
    /// `""` when the message has no `Message-ID` header. Safe on a slice (`startIndex != 0`).
    public static func messageID(inMessageData data: Data) -> String {
        RFC822Parser.messageID(in: RFC822Parser.parseHeaders(from: data))
    }

    /// Largest header block `readMessageID` will look at. A message whose header block is not
    /// finished within this many bytes is unreadable, whatever its line endings: the bytes are
    /// sender-controlled, so the read is capped instead of following the message to its end.
    public static let maxHeaderScanBytes = 256 * 1024

    /// The header block did not end within `maxHeaderScanBytes` (or the cap passed in).
    public struct HeaderBlockTooLarge: Error, Equatable {}

    /// The Message-ID of the message in the .emlx file at `path`, looking at no more than the
    /// first `maxHeaderBytes` of the message (#682).
    ///
    /// The first 4096 bytes of the file are read to find the length line, whatever they hold: with
    /// a small `maxHeaderBytes` they can already contain message bytes, so the cap bounds the bytes
    /// of the message read after that probe, not the probe itself. The message then comes in
    /// `chunkSize` pieces and the read stops once a blank line, `\r\n\r\n` or `\n\n`, has been
    /// seen: the header block ends there (`RFC822Parser`). A message that ends inside the cap is
    /// parsed whole; a longer one whose header block does not end inside the cap throws
    /// `HeaderBlockTooLarge`. A file shorter than its length line promises, or a length line that
    /// does not parse within those 4096 bytes, throws, as `readEmail` does for the short file.
    /// Whenever this returns, the value is the one `readEmail` extracts for the same file.
    ///
    /// - Parameters:
    ///   - chunkSize: bytes per read of the message; tests use small values.
    ///   - maxHeaderBytes: the cap on bytes of the message read after the length-line probe.
    ///   - bytesRead: called with the size of every read (tests pin the bound with it).
    public static func readMessageID(
        atPath path: String, chunkSize: Int = 32 * 1024, maxHeaderBytes: Int = maxHeaderScanBytes,
        bytesRead: ((Int) -> Void)? = nil
    ) throws -> String {
        let step = max(chunkSize, 1)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: 4096) ?? Data()
        bytesRead?(head.count)
        let prefix = try EmlxFormat.parseLengthPrefix(from: head)
        let messageOffset = UInt64(head.distance(from: head.startIndex, to: prefix.messageStart))
        let promised = UInt64(prefix.byteCount)
        guard messageOffset + promised <= fileSize else {
            throw MailSQLiteError.emlxParseFailed(
                "Insufficient data: expected \(prefix.byteCount) bytes after header, "
                + "but only \(fileSize - min(messageOffset, fileSize)) available")
        }

        try handle.seek(toOffset: messageOffset)
        let target = min(prefix.byteCount, max(maxHeaderBytes, 0))
        var message = Data()
        var scanFrom = 0
        var sawBlankLine = false
        while message.count < target {
            guard let chunk = try handle.read(upToCount: min(step, target - message.count)), !chunk.isEmpty else {
                throw MailSQLiteError.emlxParseFailed("The .emlx file ended before its promised length")
            }
            bytesRead?(chunk.count)
            message.append(chunk)
            let from = max(scanFrom - 3, 0)
            if contains(message, [0x0D, 0x0A, 0x0D, 0x0A], from: from) || contains(message, [0x0A, 0x0A], from: from) {
                sawBlankLine = true
                break
            }
            scanFrom = message.count
        }
        let wholeMessage = message.count == prefix.byteCount
        if !sawBlankLine, !wholeMessage {
            throw HeaderBlockTooLarge()
        }
        return messageID(inMessageData: message)
    }

    /// Whether `data` (zero-based) holds `pattern` starting at or after `from`.
    private static func contains(_ data: Data, _ pattern: [UInt8], from: Int) -> Bool {
        let n = pattern.count
        guard from >= 0, !pattern.isEmpty, data.count >= n, from <= data.count - n else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = from
            while i <= bytes.count - n {
                var hit = true
                for k in 0..<n where bytes[i + k] != pattern[k] { hit = false; break }
                if hit { return true }
                i += 1
            }
            return false
        }
    }
}

/// Resolves the Message-ID of search rows for `search_emails` with `include_message_id` (#682).
///
/// One instance per search call: it remembers each mailbox's store folder, so a call looks the
/// folder up once per mailbox instead of once per row. A row is never dropped; one whose value
/// cannot be read is `unreadable` and the caller leaves the key out.
public final class MessageIDLookup {

    /// The longest Message-ID value returned, in UTF-8 bytes. A longer one is `unreadable(.tooLong)`:
    /// a header that size is not an identifier, and rows of it would blow up the response.
    public static let maxLength = 4096

    /// Why a row has no value. The raw values are the stderr wording, so none carries file text.
    public enum Unreadable: String, Sendable, Hashable {
        case noEmlx = "no readable .emlx file for the message"
        case readFailed = "the .emlx file could not be read"
        case tooLong = "the Message-ID is longer than 4096 bytes"
        case headerTooLarge = "the header block is larger than 256 KiB"
    }

    public enum Outcome: Equatable, Sendable {
        /// The parsed value; `""` means the header block has no `Message-ID` header.
        case value(String)
        case unreadable(Unreadable)
    }

    public struct Outcomes: Sendable {
        /// One outcome per input row, in order.
        public let rows: [Outcome]
        public let unreadableCounts: [Unreadable: Int]
    }

    private let readFile: (String) throws -> String
    private let storeFinder: (String) -> String?
    private var storeFolders: [String: String?] = [:]

    /// - Parameters:
    ///   - readFile: reads the Message-ID from a file path; tests count or fail it.
    ///   - storeFinder: finds the store folder inside a mailbox directory; tests count it.
    public init(
        readFile: @escaping (String) throws -> String = { try EmlxParser.readMessageID(atPath: $0) },
        storeFinder: ((String) -> String?)? = nil
    ) {
        self.readFile = readFile
        self.storeFinder = storeFinder ?? { EmlxParser.findStoreUUID(in: $0) }
    }

    public func outcome(for row: SearchResult) -> Outcome {
        guard let url = row.mailboxURL,
              let resolved = EmlxParser.resolveEmlxPathDetailed(
                  rowId: row.id, mailboxURL: url, storeFinder: cachedStoreFinder)
        else { return .unreadable(.noEmlx) }
        do {
            let value = try readFile(resolved.path)
            return value.utf8.count > Self.maxLength ? .unreadable(.tooLong) : .value(value)
        } catch is EmlxParser.HeaderBlockTooLarge {
            return .unreadable(.headerTooLarge)
        } catch {
            return .unreadable(.readFailed)
        }
    }

    public func outcomes(for rows: [SearchResult]) -> Outcomes {
        var counts: [Unreadable: Int] = [:]
        let all = rows.map { row -> Outcome in
            let result = outcome(for: row)
            if case .unreadable(let why) = result { counts[why, default: 0] += 1 }
            return result
        }
        return Outcomes(rows: all, unreadableCounts: counts)
    }

    private func cachedStoreFinder(_ mailboxDir: String) -> String? {
        if let known = storeFolders[mailboxDir] { return known }
        let found = storeFinder(mailboxDir)
        storeFolders[mailboxDir] = .some(found)
        return found
    }
}
