import XCTest
@testable import MailSQLite

/// #561: the shipped binary (stamped sdk 13.0) and `swift test` (the `xctest`
/// host, stamped with the current SDK) disagree on what
/// `String(data:encoding: .ascii)` does with a non-ASCII byte. None of these
/// tests can see that difference directly, so they pin what the code does now
/// that it no longer calls it: every expected value holds under either stamp.
final class ByteDecodingTests: XCTestCase {

    private func trimmed(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - The helpers

    func testIsASCIIStopsAtTheFirstHighByte() {
        XCTAssertTrue(ByteDecoding.isASCII(Data()))
        XCTAssertTrue(ByteDecoding.isASCII(Data([0x00, 0x7F])))
        XCTAssertFalse(ByteDecoding.isASCII(Data([0x41, 0x80])))
    }

    func testLatin1StringIsLosslessForEveryByte() {
        let bytes = Data(0...255)
        let scalars = ByteDecoding.latin1String(bytes).unicodeScalars.map { UInt8($0.value) }
        XCTAssertEqual(Data(scalars), bytes)
    }

    func testUTF8OrLatin1PrefersValidUTF8() {
        XCTAssertEqual(ByteDecoding.utf8OrLatin1(Data("日本語".utf8)), "日本語")
        XCTAssertEqual(ByteDecoding.utf8OrLatin1(Data([0x63, 0x61, 0x66, 0xE9])), "café")
    }

    func testStrictUTF8AcceptsValidInput() {
        XCTAssertEqual(ByteDecoding.strictUTF8(Data()), "")
        XCTAssertEqual(ByteDecoding.strictUTF8(Data("a日𠮷".utf8)), "a日𠮷")
        XCTAssertEqual(ByteDecoding.strictUTF8(Data("\u{FFFD}".utf8)), "\u{FFFD}", "a real U+FFFD is not a repair")
        XCTAssertEqual(ByteDecoding.strictUTF8(Data([0x61, 0x00, 0x62])), "a\u{0}b")
    }

    func testStrictUTF8RejectsEveryInvalidShape() {
        let invalid: [(String, [UInt8])] = [
            ("lone continuation", [0x80]),
            ("lone lead", [0xE9]),
            ("truncated sequence", [0xE6, 0x97]),
            ("overlong NUL", [0xC0, 0x80]),
            ("overlong slash", [0xE0, 0x80, 0xAF]),
            ("surrogate", [0xED, 0xA0, 0x80]),
            ("above U+10FFFF", [0xF4, 0x90, 0x80, 0x80]),
            ("invalid byte", [0xFF])
        ]
        for (label, bytes) in invalid {
            XCTAssertNil(ByteDecoding.strictUTF8(Data(bytes)), label)
            XCTAssertNil(ByteDecoding.strictUTF8(Data([0x61] + bytes + [0x62])), label + " inside text")
        }
    }

    func testStrictUTF8DropsOnlyALeadingByteOrderMark() {
        XCTAssertEqual(ByteDecoding.strictUTF8(Data([0xEF, 0xBB, 0xBF, 0x61])), "a")
        XCTAssertEqual(ByteDecoding.strictUTF8(Data([0x61, 0xEF, 0xBB, 0xBF]))?.unicodeScalars.count, 2)
    }

    func testAnASCIILabelNeverFails() {
        XCTAssertEqual(ByteDecoding.string(from: Data("plain".utf8), encoding: .ascii), "plain")
        XCTAssertEqual(ByteDecoding.string(from: Data("日".utf8), encoding: .ascii), "日")
        XCTAssertEqual(ByteDecoding.string(from: Data([0xE9]), encoding: .ascii), "é")
    }

    func testOtherLabelsStillFailOnBytesTheyCannotDecode() {
        XCTAssertNil(ByteDecoding.string(from: Data([0xE9]), encoding: .utf8))
    }

    // MARK: - Header block

    func testHeaderBlockWithANonUTF8ByteKeepsItsHeaders() {
        // Raw 8-bit Big5 in Subject; the block as a whole is not valid UTF-8.
        var raw = Data("From: a@example.invalid\r\nSubject: ".utf8)
        raw.append(contentsOf: [0xA4, 0xA4])
        raw.append(Data("\r\nMessage-ID: <m@example.invalid>\r\n\r\nbody".utf8))
        let headers = RFC822Parser.parseHeaders(from: raw)
        XCTAssertEqual(headers["from"], "a@example.invalid")
        XCTAssertEqual(headers["message-id"], "<m@example.invalid>")
        XCTAssertEqual(headers["subject"], "\u{A4}\u{A4}")
    }

    // MARK: - Transfer encodings

    func testQuotedPrintableBytesKeepARawHighByte() throws {
        // "café" as raw UTF-8, then =20: a stray 8-bit run in a QP part.
        var raw = Data("caf".utf8)
        raw.append(contentsOf: [0xC3, 0xA9])
        raw.append(Data("=20x".utf8))
        XCTAssertEqual(RFC822Parser.decodeQuotedPrintableBytes(raw), Data("café x".utf8))
    }

    func testQuotedPrintableBytesHandleSoftBreaksAndATruncatedEscape() {
        XCTAssertEqual(RFC822Parser.decodeQuotedPrintableBytes(Data("a=\r\nb=\nc=".utf8)), Data("abc=".utf8))
        XCTAssertEqual(RFC822Parser.decodeQuotedPrintableBytes(Data("a=4".utf8)), Data("a=4".utf8))
        XCTAssertEqual(RFC822Parser.decodeQuotedPrintableBytes(Data([0x3D, 0xE9])), Data([0x3D, 0xE9]))
    }

    // #626: the end-of-input guard ran before the soft-break test, so a break
    // that was the last thing in the input was written out with its `=`.

    func testASoftBreakAtTheEndOfTheInputIsDropped() {
        for input in ["abc=\r\n", "abc=\n", "abc=\r"] {
            let label = input.debugDescription
            XCTAssertEqual(RFC822Parser.decodeQuotedPrintableBytes(Data(input.utf8)), Data("abc".utf8), label)
            XCTAssertEqual(RFC822Parser.decodeQuotedPrintableBytes(input), Data("abc".utf8), label)
        }
    }

    func testATruncatedEscapeAtTheEndOfTheInputStaysLiteral() {
        for input in ["abc=X", "abc=", "abc=4"] {
            XCTAssertEqual(RFC822Parser.decodeQuotedPrintableBytes(Data(input.utf8)), Data(input.utf8), input)
            XCTAssertEqual(RFC822Parser.decodeQuotedPrintableBytes(input), Data(input.utf8), input)
        }
    }

    func testASoftBreakBeforeMoreTextStillJoinsTheLines() {
        for input in ["abc=\r\ndef", "abc=\ndef", "abc=\rdef"] {
            let label = input.debugDescription
            XCTAssertEqual(RFC822Parser.decodeQuotedPrintableBytes(Data(input.utf8)), Data("abcdef".utf8), label)
            XCTAssertEqual(RFC822Parser.decodeQuotedPrintableBytes(input), Data("abcdef".utf8), label)
        }
    }

    func testAMultipartQuotedPrintablePartEndingInASoftBreakHasNoStrayEquals() {
        // Multipart text keeps the line break before the boundary (#546), so a
        // part that ends in a soft break hands the decoder exactly this tail.
        let body = "--b626\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Transfer-Encoding: quoted-printable\r\n"
            + "\r\n"
            + "line one=\r\n"
            + "--b626--\r\n"
        let result = MIMEParser.parseBody(Data(body.utf8), headers: [
            "content-type": "multipart/mixed; boundary=b626"
        ])
        XCTAssertEqual(result.textBody, "line one")
    }

    func testQuotedPrintableStringOverloadStillEncodesLiteralsAsUTF8() {
        XCTAssertEqual(RFC822Parser.decodeQuotedPrintableBytes("日=20本"), Data("日 本".utf8))
    }

    func testQuotedPrintablePartWithRawUTF8DecodesItsEscapes() {
        var body = Data("caf".utf8)
        body.append(contentsOf: [0xC3, 0xA9])
        body.append(Data("=20x".utf8))
        let result = MIMEParser.parseBody(body, headers: [
            "content-type": "text/plain; charset=utf-8",
            "content-transfer-encoding": "quoted-printable"
        ])
        XCTAssertEqual(result.textBody, "café x")
    }

    func testBase64PartWithFoldedLinesDecodes() {
        let body = Data("SGVs\r\nbG8s\nIHdv cmxkIQ==\r\n".utf8)
        let result = MIMEParser.parseBody(body, headers: [
            "content-type": "text/plain; charset=utf-8",
            "content-transfer-encoding": "base64"
        ])
        XCTAssertEqual(result.textBody, "Hello, world!")
    }

    func testBase64PartWithAHighByteKeepsTheRawBytes() {
        // Not decodable as base64: the raw bytes are returned, not an empty body.
        var body = Data("SGVsbG8".utf8)
        body.append(0xE9)
        let result = MIMEParser.parseBody(body, headers: [
            "content-type": "text/plain; charset=iso-8859-1",
            "content-transfer-encoding": "base64"
        ])
        XCTAssertEqual(result.textBody, "SGVsbG8é")
    }

    func testSalvageLeavesHonestEightBitTextAlone() {
        // Declared 8bit, carries a QP-looking run and a real non-ASCII byte
        // sequence: it is text, not mislabelled QP.
        let text = Data("café =E6=97=A5".utf8)
        XCTAssertEqual(MIMEParser.salvageMislabelledQuotedPrintable(text, declaredEncoding: "8bit"), text)
    }

    func testSalvageStillRescuesPureASCIIQuotedPrintable() {
        let qp = Data("=E6=97=A5=E6=9C=AC".utf8)
        XCTAssertEqual(MIMEParser.salvageMislabelledQuotedPrintable(qp, declaredEncoding: "7bit"), Data("日本".utf8))
    }

    // MARK: - ASCII labels in headers and filenames

    func testEncodedWordUnderAnASCIILabelFollowsTheBodyRule() {
        XCTAssertEqual(RFC822Parser.decodeRFC2047("=?us-ascii?Q?caf=E9?="), "café")
        XCTAssertEqual(RFC822Parser.decodeRFC2047("=?us-ascii?B?5pel?="), "日")
        XCTAssertEqual(RFC822Parser.decodeRFC2047("=?us-ascii?Q?plain?="), "plain")
    }

    func testPercentEncodedFilenameUnderAnASCIILabelFollowsTheBodyRule() {
        XCTAssertEqual(MIMEParser.decodePercentEncoded("%E6%97%A5.txt", charset: "us-ascii"), "日.txt")
        XCTAssertEqual(MIMEParser.decodePercentEncoded("caf%E9.txt", charset: "us-ascii"), "café.txt")
    }

    func testBodyUnderAnASCIILabelFollowsTheSameRule() {
        XCTAssertEqual(MIMEParser.decodeBodyText(Data([0x63, 0x61, 0x66, 0xE9]), declaredCharset: "us-ascii"), "café")
        XCTAssertEqual(MIMEParser.decodeBodyText(Data("日".utf8), declaredCharset: "us-ascii"), "日")
    }
}
