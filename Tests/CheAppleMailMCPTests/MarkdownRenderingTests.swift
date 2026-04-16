import XCTest
@testable import CheAppleMailMCP

final class MarkdownRenderingTests: XCTestCase {

    // MARK: - renderBody: plain mode

    func testRenderBody_plain_passesBodyThrough() throws {
        let body = "Hi\n\n*Regards*"
        let result = try renderBody(body, format: .plain)

        XCTAssertNil(result.htmlContent, "plain mode must not produce htmlContent")
        XCTAssertEqual(result.plainContent, body)
    }

    // MARK: - renderBody: html mode

    func testRenderBody_html_passesHTMLThrough() throws {
        let body = "<b>bold</b> <a href=\"https://example.com\">link</a>"
        let result = try renderBody(body, format: .html)

        XCTAssertEqual(result.htmlContent, body, "html mode must pass body through unchanged")
        XCTAssertEqual(result.plainContent, body, "plainContent fallback should still be set")
    }

    // MARK: - renderBody: markdown mode

    func testRenderBody_markdown_bold_producesBoldHTML() throws {
        let result = try renderBody("**bold**", format: .markdown)

        let html = result.htmlContent ?? ""
        XCTAssertTrue(html.contains("bold"), "HTML must contain literal word 'bold'")
        XCTAssertTrue(
            html.contains("<b>") || html.contains("<strong") || html.lowercased().contains("font-weight: bold") || html.lowercased().contains("font-weight:bold"),
            "HTML must carry a bold indicator, got: \(html)"
        )
    }

    func testRenderBody_markdown_italic_producesItalicHTML() throws {
        let result = try renderBody("*italic*", format: .markdown)

        let html = result.htmlContent ?? ""
        XCTAssertTrue(html.contains("italic"))
        XCTAssertTrue(
            html.contains("<i>") || html.contains("<em") || html.lowercased().contains("font-style: italic") || html.lowercased().contains("font-style:italic"),
            "HTML must carry an italic indicator, got: \(html)"
        )
    }

    func testRenderBody_markdown_link_producesAnchorHTML() throws {
        let result = try renderBody("See [example](https://example.com)", format: .markdown)

        let html = result.htmlContent ?? ""
        XCTAssertTrue(html.contains("example"))
        XCTAssertTrue(
            html.contains("href=\"https://example.com\"") || html.contains("href='https://example.com'"),
            "HTML must contain anchor href, got: \(html)"
        )
    }

    func testRenderBody_markdown_inlineCode_producesCodeHTML() throws {
        let result = try renderBody("use `let x = 1`", format: .markdown)

        let html = result.htmlContent ?? ""
        XCTAssertTrue(html.contains("let x = 1"))
        XCTAssertTrue(
            html.contains("<code") || html.lowercased().contains("monospace") || html.contains("courier"),
            "HTML must carry an inline-code indicator, got: \(html)"
        )
    }

    func testRenderBody_markdown_stripsRawAsterisks() throws {
        let result = try renderBody("**bold**", format: .markdown)

        let html = result.htmlContent ?? ""
        XCTAssertFalse(html.contains("**bold**"), "raw markdown delimiters must not survive")
    }

    // MARK: - htmlEscape: Reply/forward original content path

    func testHTMLEscape_escapesLTGTAmp() {
        XCTAssertEqual(htmlEscape("<script>alert(\"hi\")</script>"), "&lt;script&gt;alert(&quot;hi&quot;)&lt;/script&gt;")
    }

    func testHTMLEscape_escapesAmpersandFirst() {
        // If & was escaped last, "<" → "&lt;" → "&amp;lt;" (double-escape bug)
        XCTAssertEqual(htmlEscape("<"), "&lt;")
        XCTAssertEqual(htmlEscape("&"), "&amp;")
        XCTAssertEqual(htmlEscape("& <"), "&amp; &lt;")
    }

    func testHTMLEscape_escapesApostropheAndQuote() {
        XCTAssertEqual(htmlEscape("it's \"fine\""), "it&#39;s &quot;fine&quot;")
    }

    func testHTMLEscape_preservesNonSpecialCharacters() {
        XCTAssertEqual(htmlEscape("hello world"), "hello world")
        XCTAssertEqual(htmlEscape(""), "")
    }

    // MARK: - Error wrapping contract

    func testMarkdownRenderingError_parseFailureCarriesReason() {
        let err = MarkdownRenderingError.markdownParseFailure(reason: "underlying detail")
        guard case .markdownParseFailure(let reason) = err else {
            XCTFail("Expected .markdownParseFailure case")
            return
        }
        XCTAssertEqual(reason, "underlying detail")
    }
}
