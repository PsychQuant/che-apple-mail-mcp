import XCTest
@testable import MailSQLite

/// #546: the text/html walk behind `parseBody` turned the whole multipart body
/// into one `String`, so a single byte that is neither UTF-8 nor ASCII blanked
/// both bodies, and it recursed into nested multiparts with no depth limit.
final class MultipartBodyWalkTests: XCTestCase {

    private func data(_ pieces: [Any]) -> Data {
        var out = Data()
        for piece in pieces {
            if let s = piece as? String { out.append(Data(s.utf8)) }
            if let b = piece as? [UInt8] { out.append(contentsOf: b) }
        }
        return out
    }

    private func trimmed(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - A non-UTF-8 part does not affect its siblings

    func testBig5PlainPartDoesNotBlankTheHtmlSibling() {
        // 中文 in Big5 is A4 A4 A4 E5: 0xA4 is a UTF-8 continuation byte, so the
        // part is neither valid UTF-8 nor ASCII.
        let body = data([
            "--BB\r\n",
            "Content-Type: text/plain; charset=big5\r\n",
            "Content-Transfer-Encoding: 8bit\r\n",
            "\r\n",
            [0xA4, 0xA4, 0xA4, 0xE5] as [UInt8],
            "\r\n--BB\r\n",
            "Content-Type: text/html; charset=utf-8\r\n",
            "Content-Transfer-Encoding: quoted-printable\r\n",
            "\r\n",
            "<p>=E4=B8=AD</p>\r\n",
            "--BB--\r\n"
        ])
        let result = MIMEParser.parseBody(body, headers: ["content-type": "multipart/alternative; boundary=BB"])
        XCTAssertEqual(trimmed(result.htmlBody), "<p>中</p>")
        XCTAssertEqual(trimmed(result.textBody), "中文")
    }

    func testLoneLatin1ByteInOnePartKeepsTheOtherPart() {
        let body = data([
            "--BB\r\n",
            "Content-Type: text/plain; charset=us-ascii\r\n",
            "\r\n",
            "caf", [0xE9] as [UInt8],
            "\r\n--BB\r\n",
            "Content-Type: text/html; charset=utf-8\r\n",
            "\r\n",
            "<p>ok</p>\r\n",
            "--BB--\r\n"
        ])
        let result = MIMEParser.parseBody(body, headers: ["content-type": "multipart/alternative; boundary=BB"])
        XCTAssertEqual(trimmed(result.htmlBody), "<p>ok</p>")
        XCTAssertEqual(trimmed(result.textBody), "café")
    }

    func testNonUTF8BytesInANestedPartKeepTheOuterSibling() {
        let body = data([
            "--OUT\r\n",
            "Content-Type: multipart/alternative; boundary=IN\r\n",
            "\r\n",
            "--IN\r\n",
            "Content-Type: text/plain; charset=big5\r\n",
            "Content-Transfer-Encoding: 8bit\r\n",
            "\r\n",
            [0xA4, 0xA4] as [UInt8],
            "\r\n--IN--\r\n",
            "--OUT\r\n",
            "Content-Type: text/html; charset=utf-8\r\n",
            "\r\n",
            "<p>outer</p>\r\n",
            "--OUT--\r\n"
        ])
        let result = MIMEParser.parseBody(body, headers: ["content-type": "multipart/mixed; boundary=OUT"])
        XCTAssertEqual(trimmed(result.textBody), "中")
        XCTAssertEqual(trimmed(result.htmlBody), "<p>outer</p>")
    }

    // MARK: - Well-formed UTF-8 mail keeps today's output

    func testWellFormedPartsKeepTheirTrailingLineBreak() {
        // The string walk kept the CRLF before the next delimiter in the body;
        // the byte walk must keep it too, so exported bodies do not change.
        let body = "--B\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nplain\r\n"
            + "--B\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>html</p>\r\n--B--\r\n"
        let result = MIMEParser.parseBody(Data(body.utf8), headers: ["content-type": "multipart/alternative; boundary=B"])
        XCTAssertEqual(result.textBody, "plain\r\n")
        XCTAssertEqual(result.htmlBody, "<p>html</p>\r\n")
    }

    func testLFOnlyPartsKeepTheirTrailingLineBreak() {
        let body = "--B\nContent-Type: text/plain; charset=utf-8\n\nplain\n"
            + "--B\nContent-Type: text/html; charset=utf-8\n\n<p>html</p>\n--B--\n"
        let result = MIMEParser.parseBody(Data(body.utf8), headers: ["content-type": "multipart/alternative; boundary=B"])
        XCTAssertEqual(result.textBody, "plain\n")
        XCTAssertEqual(result.htmlBody, "<p>html</p>\n")
    }

    // MARK: - Depth limit

    /// `levels` nested multiparts with one text/plain leaf at the bottom.
    /// Boundaries end in `Z` so no boundary is a prefix of another.
    private func nested(levels: Int) -> (Data, [String: String]) {
        var prefix: [String] = []
        var suffix: [String] = []
        for i in 0..<levels {
            let inner = i + 1 < levels ? "multipart/alternative; boundary=B\(i + 1)Z" : "text/plain; charset=utf-8"
            prefix.append("--B\(i)Z\r\nContent-Type: \(inner)\r\n\r\n")
            suffix.append("\r\n--B\(i)Z--\r\n")
        }
        let text = prefix.joined() + "inner" + suffix.reversed().joined()
        return (Data(text.utf8), ["content-type": "multipart/alternative; boundary=B0Z"])
    }

    func testLeafJustInsideTheDepthLimitIsFound() {
        // The top-level multipart is depth 0, so a leaf under N multiparts is at
        // depth N. Depth maxMultipartDepth - 1 is the deepest the attachment
        // walk (`collectParts`) still visits.
        let (body, headers) = nested(levels: MIMEParser.maxMultipartDepth - 1)
        XCTAssertEqual(trimmed(MIMEParser.parseBody(body, headers: headers).textBody), "inner")
        XCTAssertEqual(MIMEParser.parseAllParts(body, headers: headers).count, 1)
    }

    func testLeafBeyondTheDepthLimitIsNotWalked() {
        let (body, headers) = nested(levels: MIMEParser.maxMultipartDepth)
        XCTAssertNil(MIMEParser.parseBody(body, headers: headers).textBody)
        XCTAssertEqual(MIMEParser.parseAllParts(body, headers: headers).count, 0,
                       "parseBody and parseAllParts must stop at the same depth")
    }

    func testATruncatedBranchKeepsItsShallowSibling() {
        // A branch nested past the limit is dropped, but what the walk found
        // beside it is still returned.
        let (deep, _) = nested(levels: MIMEParser.maxMultipartDepth)
        let body = data([
            "--TOPZ\r\n",
            "Content-Type: multipart/alternative; boundary=B0Z\r\n",
            "\r\n",
            String(decoding: deep, as: UTF8.self),
            "\r\n--TOPZ\r\n",
            "Content-Type: text/html; charset=utf-8\r\n",
            "\r\n",
            "<p>sibling</p>\r\n",
            "--TOPZ--\r\n"
        ])
        let result = MIMEParser.parseBody(body, headers: ["content-type": "multipart/mixed; boundary=TOPZ"])
        XCTAssertNil(result.textBody)
        XCTAssertEqual(trimmed(result.htmlBody), "<p>sibling</p>")
    }

    func testDeepNestingReturnsPromptly() {
        let (body, headers) = nested(levels: 3000)
        let start = Date()
        let result = MIMEParser.parseBody(body, headers: headers)
        XCTAssertNil(result.textBody)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the walk must stop at the depth limit")
    }
}
