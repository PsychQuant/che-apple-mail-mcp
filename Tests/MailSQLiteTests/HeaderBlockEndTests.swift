import XCTest
@testable import MailSQLite

/// #715 — the header block ends at the earliest blank line of either kind.
///
/// `parseHeaders` and `headerBodySplitOffset` used to look for `\r\n\r\n` over
/// the whole data first and use `\n\n` only when no CRLF blank line existed
/// anywhere, so a message whose header block ended with an LF blank line and
/// that had a CRLF blank line later was split at the later one. Both functions
/// now take the blank line that starts first (RFC 5322 section 2.1).
///
/// Fixtures are synthetic. Every row is run on the data as is and on a slice
/// whose `startIndex` is not 0 (#72).
final class HeaderBlockEndTests: XCTestCase {

    // MARK: - Function level

    private struct Row {
        let name: String
        let raw: String
        /// Where the body starts, relative to the first byte; nil = no blank line.
        let bodyStart: Int?
        let headers: [String: String]
    }

    private let rows: [Row] = [
        // The reported shape: LF blank line first, a CRLF blank line later.
        Row(name: "LF blank line, later CRLF blank line",
            raw: "A: 1\n\nB: x\r\n\r\nbody", bodyStart: 6, headers: ["a": "1"]),
        // The reverse order already worked; pinned so both orders stay put.
        Row(name: "CRLF blank line, later LF blank line",
            raw: "A: 1\r\n\r\nB: x\n\nbody", bodyStart: 8, headers: ["a": "1"]),
        Row(name: "all CRLF",
            raw: "A: 1\r\nB: 2\r\n\r\nbody", bodyStart: 14, headers: ["a": "1", "b": "2"]),
        Row(name: "all LF",
            raw: "A: 1\nB: 2\n\nbody", bodyStart: 11, headers: ["a": "1", "b": "2"]),
        Row(name: "no blank line",
            raw: "A: 1\r\nB: 2", bodyStart: nil, headers: ["a": "1", "b": "2"]),
        Row(name: "no blank line, LF",
            raw: "A: 1\nB: 2\n", bodyStart: nil, headers: ["a": "1", "b": "2"]),
        Row(name: "LF blank line at the very start",
            raw: "\n\nA: 1", bodyStart: 2, headers: [:]),
        Row(name: "CRLF blank line at the very start",
            raw: "\r\n\r\nA: 1", bodyStart: 4, headers: [:]),
        Row(name: "LF blank line at the very end",
            raw: "A: 1\n\n", bodyStart: 6, headers: ["a": "1"]),
        Row(name: "CRLF blank line at the very end",
            raw: "A: 1\r\n\r\n", bodyStart: 8, headers: ["a": "1"]),
        Row(name: "empty", raw: "", bodyStart: nil, headers: [:]),
        Row(name: "one byte", raw: "A", bodyStart: nil, headers: [:]),
        Row(name: "two bytes, blank line", raw: "\n\n", bodyStart: 2, headers: [:]),
        Row(name: "two bytes, no blank line", raw: "A\n", bodyStart: nil, headers: [:]),
        Row(name: "three bytes, blank line", raw: "A\n\n", bodyStart: 3, headers: [:]),
        Row(name: "three bytes, CR LF CR", raw: "\r\n\r", bodyStart: nil, headers: [:]),
        Row(name: "four bytes, CRLF blank line", raw: "\r\n\r\n", bodyStart: 4, headers: [:]),
        // Blank lines whose two line ends differ (diagnosis on #715).
        // `\r\n\n` matches as `\n\n` at its second byte; the header slice then
        // ends in a lone CR, which must not leak into the last value.
        Row(name: "CR LF LF blank line",
            raw: "A: 1\r\n\nbody", bodyStart: 7, headers: ["a": "1"]),
        Row(name: "CR LF LF blank line, later CRLF blank line",
            raw: "A: 1\r\n\nB: x\r\n\r\nbody", bodyStart: 7, headers: ["a": "1"]),
        // `\n\r\n` matches neither pattern: not a blank line, same as before.
        Row(name: "LF CR LF CR is not a blank line",
            raw: "\n\r\n\r", bodyStart: nil, headers: [:]),
        // A stray LF LF inside otherwise CRLF headers ends the block there
        // (RFC 5322 section 2.1: the first empty line).
        Row(name: "stray LF LF inside CRLF headers",
            raw: "A: 1\r\nB: 2\n\nC: 3\r\n\r\nbody", bodyStart: 12, headers: ["a": "1", "b": "2"]),
        Row(name: "LF CR LF is not a blank line",
            raw: "A: 1\n\r\nB: 2\r\n\r\nbody", bodyStart: 15, headers: ["a": "1", "b": "2"]),
    ]

    /// `raw` as Data, or as a slice of a larger buffer so that `startIndex` is 5
    /// and `endIndex` is short of the base end. The padding holds blank lines of
    /// its own (`\n\n` before, `\n\r\n` after), so a scan that starts before
    /// `startIndex` or runs past `endIndex` returns a different value instead of
    /// only trapping. Returns the data and its start.
    private func data(_ raw: String, sliced: Bool) -> (Data, Int) {
        let bytes = Data(raw.utf8)
        guard sliced else { return (bytes, 0) }
        var base = Data("\n\nXXX".utf8)
        base.append(bytes)
        base.append(Data("\n\r\n".utf8))
        return (base[5..<(5 + bytes.count)], 5)
    }

    func testBodySplitOffsetEndsTheHeaderBlockAtTheFirstBlankLine() {
        for sliced in [false, true] {
            for row in rows {
                let (d, start) = data(row.raw, sliced: sliced)
                let got = RFC822Parser.headerBodySplitOffset(in: d)
                XCTAssertEqual(got, row.bodyStart.map { $0 + start },
                               "\(row.name) (sliced: \(sliced))")
            }
        }
    }

    func testParseHeadersEndsTheHeaderBlockAtTheFirstBlankLine() {
        for sliced in [false, true] {
            for row in rows {
                let (d, _) = data(row.raw, sliced: sliced)
                XCTAssertEqual(RFC822Parser.parseHeaders(from: d), row.headers,
                               "\(row.name) (sliced: \(sliced))")
            }
        }
    }

    /// A header-looking line after the first blank line must not become a header.
    func testALineAfterTheFirstBlankLineIsNeverAHeader() {
        for sliced in [false, true] {
            let (d, start) = data("Subject: real\n\nSubject: body line\r\n\r\nrest", sliced: sliced)
            XCTAssertEqual(RFC822Parser.parseHeaders(from: d)["subject"], "real")
            let offset = RFC822Parser.headerBodySplitOffset(in: d)
            XCTAssertEqual(offset, start + 15)
            XCTAssertEqual(String(decoding: d[offset!...], as: UTF8.self),
                           "Subject: body line\r\n\r\nrest")
        }
    }

    // MARK: - Through the readers

    private let accountUUID = "ABCE3A85-06BE-43BC-9B84-2CA6F325612F"
    private let storeUUID = "5FCC6F13-2CE3-48B1-907D-686244C0229A"
    private var messagesDir: URL?
    private var nextRowId = 100

    private func makeStore() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "header-block-end-\(UUID().uuidString)", isDirectory: true)
        let mailV10 = root.appendingPathComponent("Library/Mail/V10", isDirectory: true)
        let messages = mailV10
            .appendingPathComponent(accountUUID)
            .appendingPathComponent("INBOX.mbox")
            .appendingPathComponent(storeUUID)
            .appendingPathComponent("Data/Messages", isDirectory: true)
        try fm.createDirectory(at: messages, withIntermediateDirectories: true)
        let original = EnvelopeIndexReader.mailStoragePathOverride
        EnvelopeIndexReader.mailStoragePathOverride = mailV10.path
        addTeardownBlock {
            EnvelopeIndexReader.mailStoragePathOverride = original
            try? fm.removeItem(at: root)
        }
        return messages
    }

    private func install(_ message: String) throws -> Int {
        let messages = try messagesDir ?? makeStore()
        messagesDir = messages
        nextRowId += 1
        let bytes = Data(message.utf8)
        var file = Data("\(bytes.count)\n".utf8)
        file.append(bytes)
        try file.write(to: messages.appendingPathComponent("\(nextRowId).emlx"))
        return nextRowId
    }

    private var mailboxURL: String { "imap://\(accountUUID)/INBOX" }

    /// Top level: LF blank line first, a CRLF blank line later in the body, and a
    /// body line that looks like a header.
    func testReadEmailTakesTheHeadersFromTheFirstBlankLine() throws {
        let row = try install(
            "Message-ID: <real@example.invalid>\nSubject: real subject\n"
            + "From: a@example.invalid\nContent-Type: text/plain; charset=utf-8\n\n"
            + "Subject: line in body\r\n\r\nsecond paragraph\r\n")
        let content = try EmlxParser.readEmail(rowId: row, mailboxURL: mailboxURL, format: "text")
        XCTAssertEqual(content.messageId, "<real@example.invalid>")
        XCTAssertEqual(content.subject, "real subject")
        XCTAssertEqual(content.sender, "a@example.invalid")
        let body = content.textBody ?? ""
        XCTAssertTrue(body.hasPrefix("Subject: line in body"), "body starts after the first blank line: \(body)")
        XCTAssertTrue(body.contains("second paragraph"))
    }

    /// One MIME child part: the part's own header block ends with an LF blank
    /// line and its body holds a CRLF blank line.
    func testAChildPartIsSplitAtItsFirstBlankLine() throws {
        let row = try install(
            "From: a@example.invalid\r\nSubject: s\r\nMIME-Version: 1.0\r\n"
            + "Content-Type: multipart/alternative; boundary=\"BB\"\r\n\r\n"
            + "--BB\r\nContent-Type: text/plain; charset=utf-8\n\n"
            + "first paragraph\r\n\r\nsecond paragraph\r\n"
            + "--BB\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>html</p>\r\n--BB--\r\n")
        let content = try EmlxParser.readEmail(rowId: row, mailboxURL: mailboxURL, format: "text")
        let text = content.textBody ?? ""
        XCTAssertTrue(text.contains("first paragraph"), "child body lost its first paragraph: \(text)")
        XCTAssertTrue(text.contains("second paragraph"))
    }

    /// Attachment: the top-level header block ends with an LF blank line and a
    /// text part further down holds a CRLF blank line. The old scan split the
    /// whole message at that later CRLF blank line, so the top-level headers were
    /// read from the wrong block and the multipart declaration was lost.
    func testAnAttachmentIsFoundWhenALaterBlankLineUsesCRLF() throws {
        let row = try install(
            "From: a@example.invalid\nSubject: s\nMIME-Version: 1.0\n"
            + "Content-Type: multipart/mixed; boundary=\"BB\"\n\n"
            + "--BB\nContent-Type: text/plain\n\nhello\r\n\r\nworld\n"
            + "--BB\nContent-Type: application/octet-stream; name=\"a.bin\"\n"
            + "Content-Disposition: attachment; filename=\"a.bin\"\n"
            + "Content-Transfer-Encoding: base64\n\nSGVsbG8=\n--BB--\n")
        let data = try EmlxParser.attachmentData(
            rowId: row, mailboxURL: mailboxURL, attachmentName: "a.bin")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "Hello")
    }

    /// `\r\n\n` as the blank line, read through `readEmail`.
    func testReadEmailEndsTheHeaderBlockAtACrLfLfBlankLine() throws {
        let row = try install("Subject: s\r\nFrom: a@example.invalid\r\n\nbody text")
        let content = try EmlxParser.readEmail(rowId: row, mailboxURL: mailboxURL, format: "text")
        XCTAssertEqual(content.subject, "s")
        XCTAssertEqual(content.sender, "a@example.invalid")
        XCTAssertEqual(content.textBody ?? "", "body text")
    }

    /// Attachment names come from the child part's own header block: a
    /// header-looking line after the child's first blank line must not rename it.
    func testAttachmentNamesComeFromTheChildsFirstHeaderBlock() throws {
        let body = Data((
            "--BB\r\nContent-Type: application/octet-stream; name=\"a.bin\"\n\n"
            + "x\r\n\r\nContent-Type: text/plain; name=\"b.txt\"\r\n"
            + "--BB--\r\n").utf8)
        let names = try MIMEParser.enumerateAttachmentNames(
            body, headers: ["content-type": "multipart/mixed; boundary=\"BB\""])
        XCTAssertEqual(names, ["a.bin"])
    }
}
