import XCTest
@testable import MailSQLite

/// #538 — a `text/plain` body came out as mojibake (one scalar per UTF-8 byte)
/// from `get_email(format: "text")` and the Markdown export, while the same
/// message's `html_body` was fine.
///
/// Both tools read the body through `EmlxParser.readEmail`, which hands the
/// MIME tree to `MIMEParser.parsePart`. These tests drive that same entry point
/// against a synthetic mail store, so a green row means the exported file is
/// right, not just that a helper is.
///
/// What the investigation found, and what these rows pin:
///
///  - The shape the report describes — `charset=US-ASCII` + `7bit` carrying
///    quoted-printable-encoded UTF-8 — already decodes correctly (the #339
///    salvage plus a strict `.ascii` decode that fails on non-ASCII bytes and
///    lets the UTF-8 fallback run). It could not be reproduced, so those rows
///    are pins that pass before the fix.
///  - The mojibake signature in the report (C1 control characters after Latin-1
///    letters) is what `.isoLatin1` produces. `parsePart` decoded with the
///    declared charset FIRST, and a Latin-1-family decode never fails, so UTF-8
///    bytes under an `iso-8859-1` / `latin1` / `windows-1252` label always
///    became mojibake. Those rows are the RED ones.
///  - A body that is not valid UTF-8 under a US-ASCII, absent or `utf-8` label
///    returned `nil` and the renderer silently wrote the raw HTML instead.
final class BodyCharsetDecodingTests: XCTestCase {

    // MARK: - Synthetic store driven through the real entry point

    private let accountUUID = "ABCE3A85-06BE-43BC-9B84-2CA6F325612F"
    private let storeUUID = "5FCC6F13-2CE3-48B1-907D-686244C0229A"
    private var nextRowId = 100          // < 1000: the file sits directly under Data/Messages
    private var messagesDir: URL?

    /// A fake V10 store; the override is restored when the test ends.
    private func makeStore() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "body-charset-fixture-\(UUID().uuidString)", isDirectory: true)
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

    /// Write `message` as an .emlx and read it back with the production reader,
    /// in the "text" format `get_email` and the export both request.
    private func readEmail(_ message: Data) throws -> EmailContent {
        let messages = try messagesDir ?? makeStore()
        messagesDir = messages
        nextRowId += 1
        var file = Data("\(message.count)\n".utf8)
        file.append(message)
        try file.write(to: messages.appendingPathComponent("\(nextRowId).emlx"))
        return try EmlxParser.readEmail(
            rowId: nextRowId, mailboxURL: "imap://\(accountUUID)/INBOX", format: "text")
    }

    /// Quoted-printable encoding of `text` (UTF-8 bytes), 76-column soft breaks.
    private func qp(_ text: String, eol: String) -> String {
        var out = ""
        var line = ""
        for byte in text.utf8 {
            if byte == 0x0A { out += line + eol; line = ""; continue }
            let token: String
            if (byte >= 33 && byte <= 126 && byte != 61) || byte == 0x20 {
                token = String(UnicodeScalar(byte))
            } else {
                token = String(format: "=%02X", byte)
            }
            if line.count + token.count > 75 { out += line + "=" + eol; line = "" }
            line += token
        }
        return out + line
    }

    private func multipart(eol: String, textHeaders: [String], textPayload: Data,
                           htmlPayload: String) -> Data {
        var d = Data()
        func add(_ s: String) { d.append(Data(s.utf8)) }
        add(["From: Shop <news@example.invalid>", "To: me@example.invalid", "Subject: t",
             "MIME-Version: 1.0",
             "Content-Type: multipart/alternative; boundary=\"BB\"", "", "--BB"]
            .joined(separator: eol) + eol)
        add((textHeaders + ["", ""]).joined(separator: eol))
        d.append(textPayload)
        add(eol + ["--BB",
                    "Content-Type: text/html; charset=UTF-8",
                    "Content-Transfer-Encoding: quoted-printable", "",
                    htmlPayload, "--BB--", ""].joined(separator: eol))
        return d
    }

    private func singlePart(contentType: String?, cte: String? = "8bit", payload: Data) -> Data {
        var head = "From: a@example.invalid\r\nSubject: t\r\nMIME-Version: 1.0\r\n"
        if let ct = contentType { head += "Content-Type: \(ct)\r\n" }
        if let cte = cte { head += "Content-Transfer-Encoding: \(cte)\r\n" }
        var d = Data((head + "\r\n").utf8)
        d.append(payload)
        d.append(Data("\r\n".utf8))
        return d
    }

    private let cjk = "您好，這是一封測試信。本週優惠：全館商品八折。😀 謝謝！"
    private func trimmed(_ s: String?) -> String? {
        s?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - The reported shape: US-ASCII + 7bit carrying QP-encoded UTF-8 (pins)

    func testReportedShapeIsDecodedWithCRLF() throws {
        let eol = "\r\n"
        let content = try readEmail(multipart(
            eol: eol,
            textHeaders: ["Content-Transfer-Encoding: 7bit", "Content-Type: text/plain; charset=US-ASCII"],
            textPayload: Data(qp(cjk + "\n第二段，含軟換行" + String(repeating: "很長", count: 40) + "\n", eol: eol).utf8),
            htmlPayload: qp("<p>\(cjk)</p>", eol: eol)))
        XCTAssertEqual(trimmed(content.textBody)?.hasPrefix(cjk), true,
                       "the reported shape must decode to the original text, not to mojibake")
        XCTAssertEqual(trimmed(content.textBody)?.contains(String(repeating: "很長", count: 40)), true,
                       "soft line breaks must be joined")
        XCTAssertEqual(trimmed(content.htmlBody), "<p>\(cjk)</p>")
    }

    func testReportedShapeIsDecodedWithBareLF() throws {
        let eol = "\n"
        let content = try readEmail(multipart(
            eol: eol,
            textHeaders: ["Content-Transfer-Encoding: 7bit", "Content-Type: text/plain; charset=US-ASCII"],
            textPayload: Data(qp(cjk + "\n", eol: eol).utf8),
            htmlPayload: qp("<p>\(cjk)</p>", eol: eol)))
        XCTAssertEqual(trimmed(content.textBody), cjk)
        XCTAssertEqual(trimmed(content.htmlBody), "<p>\(cjk)</p>")
    }

    func testRawUTF8UnderWeakLabelsIsDecoded() throws {
        for ct in ["text/plain; charset=US-ASCII", "text/plain; charset=\"us-ascii\"", "text/plain"] {
            let content = try readEmail(singlePart(contentType: ct, payload: Data(cjk.utf8)))
            XCTAssertEqual(trimmed(content.textBody), cjk, "label: \(ct)")
        }
    }

    // MARK: - RED: a Latin-1-family label over UTF-8 bytes (D1)

    func testUTF8BytesUnderLatin1FamilyLabelsAreDecodedAsUTF8() throws {
        // 測 試 are E6 B8 AC / E8 A9 A6 — every byte is DEFINED in windows-1252,
        // so that label decodes them (to mojibake) instead of failing over.
        let text = "測試文字"
        for label in ["iso-8859-1", "ISO-8859-1", "latin1", "windows-1252", "cp1252"] {
            let content = try readEmail(singlePart(
                contentType: "text/plain; charset=\(label)", payload: Data(text.utf8)))
            XCTAssertEqual(trimmed(content.textBody), text, "label: \(label)")
        }
    }

    func testQuotedPrintableUTF8UnderLatin1LabelIsDecodedAsUTF8() throws {
        // The reported shape with a Latin-1 label: the #339 salvage fires, and
        // the recovered UTF-8 bytes must not then be read as Latin-1.
        let eol = "\r\n"
        let content = try readEmail(multipart(
            eol: eol,
            textHeaders: ["Content-Transfer-Encoding: 7bit", "Content-Type: text/plain; charset=iso-8859-1"],
            textPayload: Data(qp("測試文字\n", eol: eol).utf8),
            htmlPayload: qp("<p>測試文字</p>", eol: eol)))
        XCTAssertEqual(trimmed(content.textBody), "測試文字")
    }

    // MARK: - RED: a body that is not UTF-8 under a weak label is not dropped (D2)

    func testLatin1BytesUnderWeakLabelsAreNotDropped() throws {
        let latin1 = Data("caf".utf8) + Data([0xE9]) + Data(" ouvert".utf8)   // "café ouvert", Latin-1
        for ct in ["text/plain; charset=US-ASCII", "text/plain", "text/plain; charset=utf-8"] {
            let content = try readEmail(singlePart(contentType: ct, payload: latin1))
            XCTAssertEqual(trimmed(content.textBody), "café ouvert",
                           "a body that is not valid UTF-8 must be read as Latin-1, not dropped (label: \(ct))")
        }
    }

    // MARK: - Over-correction guards: green before and after the fix

    func testGenuineLatin1UnderLatin1LabelStaysLatin1() throws {
        let latin1 = Data("caf".utf8) + Data([0xE9]) + Data(" ouvert".utf8)
        for label in ["iso-8859-1", "latin1", "windows-1252"] {
            let content = try readEmail(singlePart(
                contentType: "text/plain; charset=\(label)", payload: latin1))
            XCTAssertEqual(trimmed(content.textBody), "café ouvert", "label: \(label)")
        }
    }

    func testDeclaredWindows1252PunctuationStaysWindows1252() throws {
        // 0x93 / 0x94 are curly quotes in windows-1252 and are not valid UTF-8
        // on their own, so the strict UTF-8 check must not claim them.
        let data = Data([0x93]) + Data("hi".utf8) + Data([0x94])
        let content = try readEmail(singlePart(contentType: "text/plain; charset=windows-1252", payload: data))
        XCTAssertEqual(trimmed(content.textBody), "\u{201C}hi\u{201D}")
    }

    func testUTF8LabelWithUTF8BytesIsUnchanged() throws {
        let content = try readEmail(singlePart(contentType: "text/plain; charset=utf-8", payload: Data(cjk.utf8)))
        XCTAssertEqual(trimmed(content.textBody), cjk)
    }

    func testBig5LabelWithBig5BytesIsUnchanged() throws {
        // 測試 in Big5 are B4 FA B8 D5 — not valid UTF-8, and the declared
        // charset is a real multi-byte one that must keep winning.
        let content = try readEmail(singlePart(
            contentType: "text/plain; charset=big5", payload: Data([0xB4, 0xFA, 0xB8, 0xD5])))
        XCTAssertEqual(trimmed(content.textBody), "測試")
    }

    func testShiftJISLabelWithShiftJISBytesIsUnchanged() throws {
        // 日本語 in Shift_JIS: 93 FA 96 7B 8C EA.
        let content = try readEmail(singlePart(
            contentType: "text/plain; charset=shift_jis",
            payload: Data([0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA])))
        XCTAssertEqual(trimmed(content.textBody), "日本語")
    }

    func testPureASCIIUnderEveryLabelIsUnchanged() throws {
        for label in ["US-ASCII", "iso-8859-1", "windows-1252", "utf-8"] {
            let content = try readEmail(singlePart(
                contentType: "text/plain; charset=\(label)", payload: Data("plain ascii".utf8)))
            XCTAssertEqual(trimmed(content.textBody), "plain ascii", "label: \(label)")
        }
    }

    func testHonestQuotedPrintableAndBase64UTF8AreUnchanged() throws {
        let qpBody = qp(cjk, eol: "\r\n")
        let viaQP = try readEmail(singlePart(
            contentType: "text/plain; charset=UTF-8", cte: "quoted-printable", payload: Data(qpBody.utf8)))
        XCTAssertEqual(trimmed(viaQP.textBody), cjk)
        let viaBase64 = try readEmail(singlePart(
            contentType: "text/plain; charset=UTF-8", cte: "base64",
            payload: Data(Data(cjk.utf8).base64EncodedString().utf8)))
        XCTAssertEqual(trimmed(viaBase64.textBody), cjk)
    }

    func testHTMLPartUnderLatin1LabelFollowsTheSameRule() throws {
        // parsePart serves text/html too; the decode rule is per body, not per type.
        let msg = singlePart(contentType: "text/html; charset=iso-8859-1",
                             payload: Data("<p>測試文字</p>".utf8))
        XCTAssertEqual(trimmed(try readEmail(msg).htmlBody), "<p>測試文字</p>")
    }
}
