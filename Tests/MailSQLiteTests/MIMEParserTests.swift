import XCTest
@testable import MailSQLite

final class MIMEParserTests: XCTestCase {

    func testPlainTextBody() {
        let headers = ["content-type": "text/plain; charset=utf-8"]
        let body = Data("Hello, world!".utf8)
        let result = MIMEParser.parseBody(body, headers: headers)
        XCTAssertEqual(result.textBody, "Hello, world!")
        XCTAssertNil(result.htmlBody)
    }

    func testHTMLBody() {
        let headers = ["content-type": "text/html; charset=utf-8"]
        let body = Data("<p>Hello</p>".utf8)
        let result = MIMEParser.parseBody(body, headers: headers)
        XCTAssertNil(result.textBody)
        XCTAssertEqual(result.htmlBody, "<p>Hello</p>")
    }

    func testBase64EncodedBody() {
        let headers = [
            "content-type": "text/plain; charset=utf-8",
            "content-transfer-encoding": "base64"
        ]
        let encoded = Data("SGVsbG8sIHdvcmxkIQ==".utf8) // "Hello, world!"
        let result = MIMEParser.parseBody(encoded, headers: headers)
        XCTAssertEqual(result.textBody, "Hello, world!")
    }

    func testQuotedPrintableBody() {
        let headers = [
            "content-type": "text/plain; charset=utf-8",
            "content-transfer-encoding": "quoted-printable"
        ]
        let qp = Data("Hello=20World".utf8)
        let result = MIMEParser.parseBody(qp, headers: headers)
        XCTAssertEqual(result.textBody, "Hello World")
    }

    func testMultipartAlternative() {
        let boundary = "----=_Part_123"
        let headers = ["content-type": "multipart/alternative; boundary=\"\(boundary)\""]
        let body = """
        ------=_Part_123\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Plain text version\r
        ------=_Part_123\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>HTML version</p>\r
        ------=_Part_123--\r
        """
        let result = MIMEParser.parseBody(Data(body.utf8), headers: headers)
        XCTAssertEqual(result.textBody, "Plain text version\r\n")
        XCTAssertEqual(result.htmlBody, "<p>HTML version</p>\r\n")
    }

    func testContentTypeParsing() {
        let (mimeType, params) = MIMEParser.parseContentType("text/html; charset=\"utf-8\"; name=test")
        XCTAssertEqual(mimeType, "text/html")
        XCTAssertEqual(params["charset"], "utf-8")
        XCTAssertEqual(params["name"], "test")
    }

    func testDefaultContentType() {
        let headers: [String: String] = [:]
        let body = Data("Hello".utf8)
        let result = MIMEParser.parseBody(body, headers: headers)
        XCTAssertEqual(result.textBody, "Hello")
    }

    func testRealEmlxParsing() throws {
        // Integration test: parse a real .emlx file
        let path = EnvelopeIndexReader.defaultDatabasePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Envelope Index not available")
        }

        let reader = try EnvelopeIndexReader(databasePath: path)
        let results = try reader.search(SearchParameters(query: "a", limit: 1))
        guard let msg = results.first else {
            throw XCTSkip("No messages found")
        }

        // Try to find and parse the .emlx file
        // We need a mailbox URL from the DB, but search results only have decoded path.
        // Skip if we can't resolve the path.
        throw XCTSkip("Full .emlx integration test requires mailbox URL from DB")
    }

    // MARK: - parseAllParts (task 2.3)

    /// Build a full RFC 822 message body with the given top-level content
    /// type and raw body bytes. Callers supply headers and the message
    /// body that `parseAllParts` would normally receive (i.e., the body
    /// after header/body split).
    private func makeMessage(contentType: String, body: String) -> (Data, [String: String]) {
        let headers = ["content-type": contentType]
        return (Data(body.utf8), headers)
    }

    func testParseAllPartsSingleTextPlainReturnsOnePart() {
        let (data, headers) = makeMessage(
            contentType: "text/plain; charset=utf-8",
            body: "Hello world"
        )
        let parts = MIMEParser.parseAllParts(data, headers: headers)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].contentType, "text/plain")
        XCTAssertEqual(String(data: parts[0].decodedData, encoding: .utf8), "Hello world")
        XCTAssertNil(parts[0].filename)
        XCTAssertNil(parts[0].contentDisposition)
    }

    func testParseAllPartsMultipartWithTextHtmlAndAttachment() {
        // Build a multipart/mixed body with three parts: text, html, attachment
        let boundary = "BOUNDARY"
        let pdfBytes = Data([0x25, 0x50, 0x44, 0x46])  // "%PDF"
        let pdfBase64 = pdfBytes.base64EncodedString()

        let body = """
        --\(boundary)\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Plain text body\r
        --\(boundary)\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>HTML body</p>\r
        --\(boundary)\r
        Content-Type: application/pdf\r
        Content-Disposition: attachment; filename="report.pdf"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(pdfBase64)\r
        --\(boundary)--\r
        """

        let headers = ["content-type": "multipart/mixed; boundary=\(boundary)"]
        let parts = MIMEParser.parseAllParts(Data(body.utf8), headers: headers)

        XCTAssertEqual(parts.count, 3, "expected text/plain + text/html + application/pdf")
        XCTAssertEqual(parts.map { $0.contentType }, ["text/plain", "text/html", "application/pdf"])

        let pdfPart = parts.first { $0.contentType == "application/pdf" }
        XCTAssertNotNil(pdfPart)
        XCTAssertEqual(pdfPart?.filename, "report.pdf")
        XCTAssertEqual(pdfPart?.contentDisposition, "attachment")
        XCTAssertEqual(pdfPart?.decodedData, pdfBytes)
    }

    func testParseAllPartsNestedMultipartAlternativeInsideMixed() {
        // multipart/mixed {
        //   multipart/alternative { text/plain, text/html }
        //   image/png attachment
        // }
        let outer = "OUTER"
        let inner = "INNER"
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])  // PNG magic
        let pngBase64 = pngBytes.base64EncodedString()

        let body = """
        --\(outer)\r
        Content-Type: multipart/alternative; boundary=\(inner)\r
        \r
        --\(inner)\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Plain\r
        --\(inner)\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>HTML</p>\r
        --\(inner)--\r
        \r
        --\(outer)\r
        Content-Type: image/png\r
        Content-Disposition: attachment; filename="logo.png"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(pngBase64)\r
        --\(outer)--\r
        """

        let headers = ["content-type": "multipart/mixed; boundary=\(outer)"]
        let parts = MIMEParser.parseAllParts(Data(body.utf8), headers: headers)

        XCTAssertEqual(parts.count, 3, "expected text/plain + text/html + image/png from nested walk")
        XCTAssertEqual(parts[0].contentType, "text/plain")
        XCTAssertEqual(parts[1].contentType, "text/html")
        XCTAssertEqual(parts[2].contentType, "image/png")
        XCTAssertEqual(parts[2].filename, "logo.png")
        XCTAssertEqual(parts[2].decodedData, pngBytes)
    }

    func testParseAllPartsMultipartMissingBoundaryReturnsEmpty() {
        // Malformed: multipart/mixed header but no boundary parameter.
        let body = Data("--anything\r\nContent-Type: text/plain\r\n\r\nHi\r\n--anything--".utf8)
        let headers = ["content-type": "multipart/mixed"]
        let parts = MIMEParser.parseAllParts(body, headers: headers)
        XCTAssertTrue(parts.isEmpty, "malformed multipart (no boundary) must return empty array")
    }

    func testParseAllPartsRecursionDepthLimit() {
        // Build a deeply nested multipart to ensure depth limit kicks in
        // without stack overflow or hang. We nest beyond maxMultipartDepth.
        let depth = MIMEParser.maxMultipartDepth + 2

        var body = "inner"
        var currentBoundary = "B\(depth)"
        var outermostBoundary = currentBoundary
        for i in (0..<depth).reversed() {
            let nextBoundary = "B\(i)"
            body = """
            --\(nextBoundary)\r
            Content-Type: multipart/mixed; boundary=\(currentBoundary)\r
            \r
            --\(currentBoundary)\r
            Content-Type: text/plain\r
            \r
            \(body)\r
            --\(currentBoundary)--\r
            --\(nextBoundary)--\r
            """
            currentBoundary = nextBoundary
            outermostBoundary = nextBoundary
        }

        let headers = ["content-type": "multipart/mixed; boundary=\(outermostBoundary)"]
        // Must not hang, crash, or loop forever. Exact count not important;
        // what matters is that it terminates.
        let parts = MIMEParser.parseAllParts(Data(body.utf8), headers: headers)
        XCTAssertTrue(
            parts.count < depth,
            "depth limit must truncate walking before exhausting all nesting levels"
        )
    }

    // MARK: - parseAllParts vs parseBody cross-check (task 2.4)

    func testParseAllPartsAndParseBodyAgreeOnTextBody() {
        let boundary = "X"
        let body = """
        --\(boundary)\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Plain text content\r
        --\(boundary)\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>HTML content</p>\r
        --\(boundary)\r
        Content-Type: application/octet-stream\r
        Content-Disposition: attachment; filename="blob.bin"\r
        \r
        unimportant\r
        --\(boundary)--\r
        """
        let headers = ["content-type": "multipart/mixed; boundary=\(boundary)"]
        let data = Data(body.utf8)

        let lossy = MIMEParser.parseBody(data, headers: headers)
        let allParts = MIMEParser.parseAllParts(data, headers: headers)

        let firstText = allParts.first(where: { $0.contentType == "text/plain" })
        let firstHTML = allParts.first(where: { $0.contentType == "text/html" })

        XCTAssertNotNil(firstText)
        XCTAssertNotNil(firstHTML)

        // parseBody uses String-based components split and keeps trailing CRLFs
        // in text bodies; parseAllParts uses byte-level split and strips them.
        // Both are semantically equivalent — compare after trimming whitespace.
        let lossyTextTrim = lossy.textBody?.trimmingCharacters(in: .whitespacesAndNewlines)
        let allPartsTextTrim = firstText
            .flatMap { String(data: $0.decodedData, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            lossyTextTrim,
            allPartsTextTrim,
            "parseBody.textBody and first parseAllParts text/plain must carry same text content"
        )

        let lossyHTMLTrim = lossy.htmlBody?.trimmingCharacters(in: .whitespacesAndNewlines)
        let allPartsHTMLTrim = firstHTML
            .flatMap { String(data: $0.decodedData, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            lossyHTMLTrim,
            allPartsHTMLTrim,
            "parseBody.htmlBody and first parseAllParts text/html must carry same text content"
        )
    }

    // MARK: - Content-Disposition / RFC 5987 filename parsing (task 3.2)

    func testFilenameFromPlainContentDisposition() {
        let boundary = "B"
        let body = """
        --\(boundary)\r
        Content-Type: application/pdf\r
        Content-Disposition: attachment; filename="report.pdf"\r
        \r
        payload\r
        --\(boundary)--\r
        """
        let headers = ["content-type": "multipart/mixed; boundary=\(boundary)"]
        let parts = MIMEParser.parseAllParts(Data(body.utf8), headers: headers)
        XCTAssertEqual(parts.first?.filename, "report.pdf")
    }

    func testFilenameFromRFC5987UTF8CJK() {
        // Content-Disposition: attachment; filename*=UTF-8''%E4%B8%AD%E6%96%87%E6%AA%94%E6%A1%88.pdf
        let boundary = "B"
        let body = """
        --\(boundary)\r
        Content-Type: application/pdf\r
        Content-Disposition: attachment; filename*=UTF-8''%E4%B8%AD%E6%96%87%E6%AA%94%E6%A1%88.pdf\r
        \r
        payload\r
        --\(boundary)--\r
        """
        let headers = ["content-type": "multipart/mixed; boundary=\(boundary)"]
        let parts = MIMEParser.parseAllParts(Data(body.utf8), headers: headers)
        XCTAssertEqual(parts.first?.filename, "中文檔案.pdf")
    }

    func testFilenameFromContentTypeName() {
        // No Content-Disposition, only Content-Type: ...; name=foo
        let boundary = "B"
        let body = """
        --\(boundary)\r
        Content-Type: application/octet-stream; name="legacy.dat"\r
        \r
        payload\r
        --\(boundary)--\r
        """
        let headers = ["content-type": "multipart/mixed; boundary=\(boundary)"]
        let parts = MIMEParser.parseAllParts(Data(body.utf8), headers: headers)
        XCTAssertEqual(parts.first?.filename, "legacy.dat")
    }

    func testFilenameWithSpacesPreserved() {
        let boundary = "B"
        let body = """
        --\(boundary)\r
        Content-Type: application/pdf\r
        Content-Disposition: attachment; filename="my document.pdf"\r
        \r
        payload\r
        --\(boundary)--\r
        """
        let headers = ["content-type": "multipart/mixed; boundary=\(boundary)"]
        let parts = MIMEParser.parseAllParts(Data(body.utf8), headers: headers)
        XCTAssertEqual(parts.first?.filename, "my document.pdf")
    }

    // MARK: - Low-level Content-Disposition helper

    func testParseContentDispositionReturnsNilForNilInput() {
        let (disposition, params) = MIMEParser.parseContentDisposition(nil)
        XCTAssertNil(disposition)
        XCTAssertTrue(params.isEmpty)
    }

    func testParseContentDispositionExtractsParams() {
        let (disposition, params) = MIMEParser.parseContentDisposition(
            "attachment; filename=\"r.pdf\"; size=12345"
        )
        XCTAssertEqual(disposition, "attachment")
        XCTAssertEqual(params["filename"], "r.pdf")
        XCTAssertEqual(params["size"], "12345")
    }

    func testDecodeRFC5987RoundTrip() {
        let decoded = MIMEParser.decodeRFC5987("UTF-8''%E4%B8%AD%E6%96%87.pdf")
        XCTAssertEqual(decoded, "中文.pdf")
    }

    // MARK: - RFC 2231 + nested RFC 2047 (#99)

    func testResolveFilename_outlook16_rfc2231WithNestedRfc2047() {
        // Outlook 16 Windows double-encodes Chinese filenames as
        // RFC 2231 §3 continuation (filename*0*, filename*1*) where the
        // percent-decoded payload is itself an RFC 2047 encoded-word
        // (=?utf-8?B?...?= sequence with literal tab between segments).
        // Fixture is the exact byte sequence captured from message id 272713
        // (see issue body).
        let params: [String: String] = [
            "filename*0*": "us-ascii''%3D%3Futf%2D8%3FB%3F5Lit5aSu56CU56m26Zmi5paw6YCy6IGY5YOx5Lq65ZOh6auU5qC85q",
            "filename*1*": "qi5p%2Bl%3F%3D%09%3D%3Futf%2D8%3FB%3F6KGoLTExMTAzMzHoo73ooagucGRm%3F%3D",
        ]
        let result = MIMEParser.resolveFilename(
            dispositionParams: params,
            contentTypeParams: [:]
        )
        XCTAssertEqual(result, "中央研究院新進聘僱人員體格檢查表-1110331製表.pdf")
    }

    func testResolveFilename_rfc5987_withNestedRfc2047() {
        // Defensive variant: RFC 5987 single-segment filename* whose
        // percent-decoded value is itself a complete encoded-word. Same
        // Outlook 16 double-encoding shape but without RFC 2231 continuation
        // split. The base64 payload `5Lit5paHLnBkZg==` is `中文.pdf` in UTF-8
        // (filename including extension is inside the encoded-word, matching
        // the real Outlook 16 fixture from issue body which packs the whole
        // name including `.pdf` inside the base64 segments).
        let params: [String: String] = [
            "filename*": "UTF-8''%3D%3Futf%2D8%3FB%3F5Lit5paHLnBkZg%3D%3D%3F%3D",
        ]
        let result = MIMEParser.resolveFilename(
            dispositionParams: params,
            contentTypeParams: [:]
        )
        XCTAssertEqual(result, "中文.pdf")
    }

    func testResolveFilename_plainFilename_unchangedWhenNotEncodedWord() {
        // Regression: plain `filename="report.pdf"` must pass through
        // unchanged — no false-positive RFC 2047 second pass.
        let params: [String: String] = ["filename": "report.pdf"]
        let result = MIMEParser.resolveFilename(
            dispositionParams: params,
            contentTypeParams: [:]
        )
        XCTAssertEqual(result, "report.pdf")
    }

    func testResolveFilename_plainFilename_containingPartialEncodedWordSubstring_unchanged() {
        // Defensive: filename literally containing `=?...?=` as a substring
        // (not a full encoded-word) must NOT be corrupted by the second-pass
        // decode. Strict full-string pattern gate should reject this.
        let params: [String: String] = ["filename": "report=?bogus.pdf"]
        let result = MIMEParser.resolveFilename(
            dispositionParams: params,
            contentTypeParams: [:]
        )
        XCTAssertEqual(result, "report=?bogus.pdf")
    }

    // MARK: - Base64-encoded multipart parts (#72)

    /// Single-layer multipart/alternative with base64-encoded HTML part.
    /// Mirrors the simplest manifestation of #72 — the HTML body is
    /// transferred as base64 and `parseBody` must decode it.
    func testParseBodyMultipartAlternativeBase64HTMLOnly() {
        let boundary = "----=_Part_b64_single"
        let headers = ["content-type": "multipart/alternative; boundary=\"\(boundary)\""]
        // base64 of "<html><body>Hello</body></html>"
        let htmlBase64 = "PGh0bWw+PGJvZHk+SGVsbG88L2JvZHk+PC9odG1sPg=="
        let body = """
        ------=_Part_b64_single\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Plain text version\r
        ------=_Part_b64_single\r
        Content-Type: text/html; charset=utf-8\r
        Content-Transfer-Encoding: base64\r
        \r
        \(htmlBase64)\r
        ------=_Part_b64_single--\r
        """
        let result = MIMEParser.parseBody(Data(body.utf8), headers: headers)
        XCTAssertEqual(result.textBody, "Plain text version\r\n")
        XCTAssertEqual(result.htmlBody, "<html><body>Hello</body></html>")
    }

    /// Nested multipart: outer multipart/mixed wraps an inner
    /// multipart/alternative whose HTML part is base64-encoded.
    /// Pattern emitted by Android Gmail (Message-ID `*@email.android.com`)
    /// and the original reproducer for #72.
    func testParseBodyNestedMultipartMixedWithAlternativeBase64HTML() {
        let outer = "----=_Outer_mixed"
        let inner = "----=_Inner_alt"
        let headers = ["content-type": "multipart/mixed; boundary=\"\(outer)\""]
        // base64 of "<html><body>Nested</body></html>"
        let htmlBase64 = "PGh0bWw+PGJvZHk+TmVzdGVkPC9ib2R5PjwvaHRtbD4="
        let body = """
        ------=_Outer_mixed\r
        Content-Type: multipart/alternative; boundary="\(inner)"\r
        MIME-Version: 1.0\r
        \r
        ------=_Inner_alt\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Plain text\r
        ------=_Inner_alt\r
        Content-Type: text/html; charset=utf-8\r
        Content-Transfer-Encoding: base64\r
        \r
        \(htmlBase64)\r
        ------=_Inner_alt--\r
        ------=_Outer_mixed--\r
        """
        let result = MIMEParser.parseBody(Data(body.utf8), headers: headers)
        XCTAssertEqual(result.textBody, "Plain text\r\n")
        XCTAssertEqual(result.htmlBody, "<html><body>Nested</body></html>")
        // Regression guard: htmlBody must not contain MIME-Version remnant.
        XCTAssertFalse(result.htmlBody?.contains("MIME-Version") ?? false)
        XCTAssertFalse(result.htmlBody?.contains("sion: 1.0") ?? false)
    }

    /// **Real reproducer for #72**:emlx-extracted Data slice with non-zero
    /// `startIndex` exposes a Data-index-vs-array-index mismatch in
    /// `RFC822Parser.headerBodySplitOffset` callers
    /// (`EmailContent.readEmail`, `EmlxParser.readHeaders`,
    /// `AttachmentExtractor`).
    ///
    /// The .emlx container is: `"<byteCount>\n<RFC822 bytes>"`.
    /// `EmlxFormat.extractMessageData` returns a `Data` slice whose
    /// `startIndex == byteCount-header-prefix-length`. Then
    /// `headerBodySplitOffset(in: messageData)` does `Array(data)` → returns
    /// a 0-based array index. Callers do `messageData[bodyOffset...]` which
    /// is interpreted as **absolute** Data index, so the body slice is off
    /// by `messageData.startIndex` bytes — exactly the symptom observed in
    /// production (`html_body` starts with `"sion: 1.0\n\n<base64>"`,
    /// the tail of `"MIME-Version: 1.0"` from the header block).
    func testEmlxToBodyExtractionPreservesSliceStartIndex() throws {
        // Synthetic .emlx: `"100\n" + RFC822 message`. The "100" prefix
        // gives messageData.startIndex == 4.
        let rfc822 = """
        Content-Type: text/html; charset="utf-8"
        Content-Transfer-Encoding: base64
        MIME-Version: 1.0

        PGh0bWw+PGJvZHk+SGVsbG88L2JvZHk+PC9odG1sPg==
        """
        let messageBytes = rfc822.replacingOccurrences(of: "\n", with: "\n").data(using: .utf8)!
        let prefix = "\(messageBytes.count)\n".data(using: .utf8)!
        var emlx = Data()
        emlx.append(prefix)
        emlx.append(messageBytes)

        let messageData = try EmlxFormat.extractMessageData(from: emlx)
        XCTAssertNotEqual(messageData.startIndex, 0,
            "Slice from extractMessageData should retain non-zero startIndex")

        // Mirror the EmailContent.readEmail flow.
        let headers = RFC822Parser.parseHeaders(from: messageData)
        XCTAssertEqual(headers["content-type"], "text/html; charset=\"utf-8\"")
        XCTAssertEqual(headers["content-transfer-encoding"], "base64")
        XCTAssertEqual(headers["mime-version"], "1.0")

        guard let bodyOffset = RFC822Parser.headerBodySplitOffset(in: messageData) else {
            XCTFail("Expected to find header/body split")
            return
        }
        let bodyData = Data(messageData[bodyOffset...])

        let parsed = MIMEParser.parseBody(bodyData, headers: headers)
        // Regression guard: htmlBody must NOT contain the MIME-Version tail
        // that production observed.
        XCTAssertFalse(parsed.htmlBody?.contains("sion: 1.0") ?? false,
            "htmlBody contains MIME-Version header tail: \(parsed.htmlBody ?? "<nil>")")
        XCTAssertEqual(parsed.htmlBody, "<html><body>Hello</body></html>")
    }

    /// `text/plain` part transferred as base64 — covers the symmetric case
    /// where the plain part (not just HTML) needs decoding.
    func testParseBodyMultipartWithBase64TextPlain() {
        let boundary = "----=_Part_b64_text"
        let headers = ["content-type": "multipart/alternative; boundary=\"\(boundary)\""]
        // base64 of "Hello, world!"
        let textBase64 = "SGVsbG8sIHdvcmxkIQ=="
        let body = """
        ------=_Part_b64_text\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: base64\r
        \r
        \(textBase64)\r
        ------=_Part_b64_text\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>HTML version</p>\r
        ------=_Part_b64_text--\r
        """
        let result = MIMEParser.parseBody(Data(body.utf8), headers: headers)
        XCTAssertEqual(result.textBody, "Hello, world!")
        XCTAssertEqual(result.htmlBody, "<p>HTML version</p>\r\n")
    }
}
