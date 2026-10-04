import XCTest
@testable import CheAppleMailMCP
@testable import MailSQLite

/// #472 — the pure parts of the experimental direct-draft path: eligibility,
/// the draft's MIME in the shape Mail stores its own drafts, the .emlx framing,
/// and the message-id hash the Envelope Index keys on.
final class DirectDraftMessageTests: XCTestCase {

    // MARK: - Eligibility

    private func check(enabled: Bool = true, format: BodyFormat = .plain, to: [String] = ["a@example.org"],
                       cc: [String] = [], bcc: [String] = [], attachments: [String] = [],
                       subject: String = "S", from: String? = "me@example.org") -> DirectDraft.Ineligible? {
        DirectDraft.eligibility(enabled: enabled, format: format, to: to, cc: cc, bcc: bcc,
                                attachments: attachments, subject: subject, fromAddress: from)
    }

    func testEligibleWhenEverythingIsInTheVerifiedRange() {
        XCTAssertNil(check())
        XCTAssertNil(check(to: ["a@example.org", "b@example.org"], subject: "中文主旨"))
    }

    func testEachIneligibleReasonIsNamed() {
        XCTAssertEqual(check(enabled: false), .disabled)
        XCTAssertEqual(check(format: .html), .format)
        XCTAssertEqual(check(attachments: ["/tmp/x.pdf"]), .attachments)
        XCTAssertEqual(check(cc: ["c@example.org"]), .ccOrBcc)
        XCTAssertEqual(check(bcc: ["c@example.org"]), .ccOrBcc)
        XCTAssertEqual(check(to: ["Ann <a@example.org>"]), .displayName)
        XCTAssertEqual(check(to: []), .noRecipient)
        XCTAssertEqual(check(subject: ""), .emptySubject)
        XCTAssertEqual(check(from: nil), .missingFromAddress)
        XCTAssertEqual(check(from: ""), .missingFromAddress)
        XCTAssertEqual(check(from: "Me <me@example.org>"), .fromNotBare)
    }

    func testTheFlagIsOffByDefault() {
        XCTAssertNil(ProcessInfo.processInfo.environment[DirectDraft.envKey])
        XCTAssertFalse(DirectDraft.isEnabled)
    }

    // MARK: - MIME

    private let date = Date(timeIntervalSince1970: 1_791_083_098)   // 2026-10-04 11:04:58 +0800
    private let doc = UUID(uuidString: "AF580473-AFC6-4962-B350-9A60D2BAF125")!
    private let local = UUID(uuidString: "0E5F3C1A-1111-4222-8333-944455556666")!
    private let boundary = UUID(uuidString: "9685C001-8FB1-45DF-BCD1-AD7AB5F8542C")!

    private func build(subject: String = "Hello", body: String = "Line one", name: String? = "Me Example") -> DirectDraft.Message {
        DirectDraft.buildMessage(fromName: name, fromAddress: "me@example.org", to: ["a@example.org", "b@example.org"],
                                 subject: subject, body: body, date: date, documentUUID: doc,
                                 messageIdLocalPart: local, boundary: boundary,
                                 mailVersion: "16.0 (3901.200.41)",
                                 timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
    }

    private func text(_ m: DirectDraft.Message) -> String { String(decoding: m.mime, as: UTF8.self) }

    func testHeadersFollowMailsDraftLayout() {
        let s = text(build())
        let header = String(s[..<s.range(of: "\n\n")!.lowerBound])
        let names = header.split(separator: "\n").filter { !$0.hasPrefix("\t") && !$0.hasPrefix(" ") }
            .map { String($0.split(separator: ":", maxSplits: 1)[0]) }
        XCTAssertEqual(names, ["Subject", "Mime-Version", "Content-Type", "X-Apple-Base-Url",
                               "X-Universally-Unique-Identifier", "X-Apple-Mail-Remote-Attachments", "From",
                               "X-Apple-Windows-Friendly", "Date", "X-Apple-Mail-Signature", "Message-Id",
                               "X-Uniform-Type-Identifier", "To"])
        XCTAssertTrue(header.contains("Mime-Version: 1.0 (Mac OS X Mail 16.0 \\(3901.200.41\\))"))
        XCTAssertTrue(header.contains("X-Universally-Unique-Identifier: AF580473-AFC6-4962-B350-9A60D2BAF125"))
        XCTAssertTrue(header.contains("Date: Sun, 4 Oct 2026 11:04:58 +0800"))
        XCTAssertTrue(header.contains("Message-Id: <0E5F3C1A-1111-4222-8333-944455556666@example.org>"))
        XCTAssertTrue(header.contains("X-Uniform-Type-Identifier: com.apple.mail-draft"))
        XCTAssertTrue(header.contains("From: Me Example <me@example.org>"))
        XCTAssertTrue(header.contains("To: a@example.org, b@example.org"))
        XCTAssertFalse(s.contains("\r"), ".emlx stores LF line endings")
    }

    func testAsciiBodyIsSevenBitHtmlWithAnEmptyPlainPart() {
        let s = text(build(body: "a < b & c\nsecond"))
        XCTAssertEqual(s.components(separatedBy: "Apple-Mail=_9685C001-8FB1-45DF-BCD1-AD7AB5F8542C").count - 1, 4,
                       "declaration + two part delimiters + closing delimiter")
        XCTAssertTrue(s.contains("Content-Type: text/plain;\n\tcharset=us-ascii\n\n\n--"), "empty plain part, as Mail stores drafts")
        XCTAssertTrue(s.contains("a &lt; b &amp; c<br>\nsecond"), "escaped, newlines as <br>")
        XCTAssertTrue(s.contains("Content-Transfer-Encoding: 7bit\nContent-Type: text/html;\n\tcharset=us-ascii"))
    }

    func testNonAsciiSubjectAndBodyRoundTripThroughTheRepoDecoders() throws {
        let subject = "測試草稿：直接寫入 — 這是一個比較長的主旨，用來確認會被拆成多個 encoded word"
        let body = "第一行 café\n第二行，含 = 等號與 很長的中文句子會被軟換行切開但解碼後必須完全一樣。"
        let m = build(subject: subject, body: body, name: "鄭澈 Che Cheng")
        let s = text(m)
        let header = String(s[..<s.range(of: "\n\n")!.lowerBound])
        XCTAssertTrue(header.unicodeScalars.allSatisfy { $0.isASCII }, "headers are pure ASCII on the wire")
        let subjectLine = header.components(separatedBy: "\nMime-Version:")[0].replacingOccurrences(of: "Subject: ", with: "")
        XCTAssertEqual(RFC822Parser.decodeRFC2047(subjectLine.replacingOccurrences(of: "\n ", with: " ")), subject)
        XCTAssertTrue(header.contains("<me@example.org>"))
        XCTAssertTrue(header.contains("=?utf-8?B?"), "the non-ASCII display name is an encoded word")
        let htmlPart = try XCTUnwrap(s.components(separatedBy: "charset=utf-8\n\n").last?
            .components(separatedBy: "\n--Apple-Mail=").first)
        XCTAssertTrue(s.contains("Content-Transfer-Encoding: quoted-printable\nContent-Type: text/html;\n\tcharset=utf-8"))
        XCTAssertTrue(htmlPart.split(separator: "\n").allSatisfy { $0.count <= 76 }, "QP lines are at most 76 chars")
        let decoded = try XCTUnwrap(RFC822Parser.decodeQuotedPrintableBytes(htmlPart))
        let html = String(decoding: decoded, as: UTF8.self)
        XCTAssertTrue(html.contains("第一行 café<br>\n第二行，含 = 等號與 很長的中文句子會被軟換行切開但解碼後必須完全一樣。"))
    }

    // MARK: - .emlx and the index keys

    func testEmlxFramingMatchesMailsLayout() throws {
        let m = build()
        let emlx = DirectDraft.emlx(mime: m.mime, flags: DirectDraft.draftFlags, date: date)
        let firstLine = emlx.prefix { $0 != 0x0A }
        XCTAssertEqual(String(decoding: firstLine, as: UTF8.self), String(m.mime.count).padding(toLength: 10, withPad: " ", startingAt: 0))
        XCTAssertEqual(try EmlxFormat.extractMessageData(from: emlx), m.mime, "the repo's own .emlx reader gets the MIME back")
        let trailer = String(decoding: emlx.suffix(from: firstLine.count + 1 + m.mime.count), as: UTF8.self)
        XCTAssertTrue(trailer.contains("<key>flags</key>\n\t<integer>8623685697</integer>"))
        XCTAssertTrue(trailer.contains("<key>date-received</key>\n\t<integer>1791083098</integer>"))
        XCTAssertEqual(m.size, m.mime.count)
    }

    func testMessageIdHashIsTheLeadingEightMD5BytesLittleEndianSigned() {
        XCTAssertEqual(DirectDraft.messageIdHash("0E5F3C1A-1111-4222-8333-944455556666@example.org"), 1571834967991677254)
        XCTAssertEqual(DirectDraft.messageIdHash("probe@example.invalid"), 2030007984244379960)
        XCTAssertEqual(build().messageIdNoBrackets, "0E5F3C1A-1111-4222-8333-944455556666@example.org")
    }
}
