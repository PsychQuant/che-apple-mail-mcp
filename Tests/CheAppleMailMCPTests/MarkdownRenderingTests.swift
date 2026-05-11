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

    // MARK: - Multi-block rendering (P0 verify finding)

    func testRenderBody_markdown_twoParagraphs_producesTwoPTags() throws {
        let result = try renderBody("Para one.\n\nPara two.", format: .markdown)
        let html = result.htmlContent ?? ""
        // Must be two distinct <p> elements, not a merged one.
        let pOpenCount = html.components(separatedBy: "<p>").count - 1
        XCTAssertGreaterThanOrEqual(pOpenCount, 2, "Multi-paragraph markdown must produce at least two <p> tags, got HTML: \(html)")
    }

    func testRenderBody_markdown_paragraphThenList_producesUlAndTwoLis() throws {
        let result = try renderBody("Intro paragraph.\n\n- first item\n- second item", format: .markdown)
        let html = result.htmlContent ?? ""
        XCTAssertTrue(html.contains("<ul>"), "missing <ul>, got: \(html)")
        XCTAssertTrue(html.contains("</ul>"), "missing </ul>, got: \(html)")
        let liCount = html.components(separatedBy: "<li>").count - 1
        XCTAssertEqual(liCount, 2, "expected 2 <li> items, got HTML: \(html)")
    }

    func testRenderBody_markdown_orderedList_threeItems_produceThreeLi() throws {
        let result = try renderBody("1. First\n2. Second\n3. Third", format: .markdown)
        let html = result.htmlContent ?? ""
        XCTAssertTrue(html.contains("<ol>"), "missing <ol>, got: \(html)")
        let liCount = html.components(separatedBy: "<li>").count - 1
        XCTAssertEqual(liCount, 3, "ordered list MUST produce 3 <li> items, got HTML: \(html)")
    }

    func testRenderBody_markdown_listThenParagraph_separatesCorrectly() throws {
        let result = try renderBody("- item a\n- item b\n\nAfter list.", format: .markdown)
        let html = result.htmlContent ?? ""
        XCTAssertTrue(html.contains("</ul>"), "list must be closed before paragraph, got: \(html)")
        XCTAssertTrue(html.contains("<p>After list.</p>"), "paragraph after list must render as own <p>, got: \(html)")
    }

    func testRenderBody_markdown_twoOrderedLists_separated_countItemsCorrectly() throws {
        let result = try renderBody("1. a\n2. b\n\n---\n\n1. x\n2. y", format: .markdown)
        let html = result.htmlContent ?? ""
        // 2 + 2 = 4 items total across two lists
        let liCount = html.components(separatedBy: "<li>").count - 1
        XCTAssertEqual(liCount, 4, "two ordered lists = 4 items, got HTML: \(html)")
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

    // MARK: - Scenario (#19): sanitize_links opt-in URL scheme allowlist

    func testRenderBody_markdown_sanitizeLinksOff_passesJavaScriptURLThrough() throws {
        // Default behavior — backwards compat. javascript: link surfaces
        // unsanitized. Same input as #19's repro example.
        let result = try renderBody("[click](javascript:alert('xss'))", format: .markdown)
        let html = result.htmlContent ?? ""
        XCTAssertTrue(html.contains("href=\"javascript:"),
                      "default sanitizeLinks=false must preserve link as-is for backwards compat; got: \(html)")
    }

    func testRenderBody_markdown_sanitizeLinksOn_dropsAnchorOnJavaScriptURL() throws {
        let result = try renderBody("[click](javascript:alert('xss'))", format: .markdown, sanitizeLinks: true)
        let html = result.htmlContent ?? ""
        XCTAssertFalse(html.contains("javascript:"),
                       "sanitizeLinks=true must NOT emit javascript: URL; got: \(html)")
        XCTAssertFalse(html.contains("<a href"),
                       "sanitizeLinks=true must NOT emit anchor for unsafe scheme; got: \(html)")
        XCTAssertTrue(html.contains("click"),
                      "anchor text must still be present (just no anchor wrap); got: \(html)")
    }

    func testRenderBody_markdown_sanitizeLinksOn_preservesHttpsLink() throws {
        let result = try renderBody("[example](https://example.com/path?q=1)", format: .markdown, sanitizeLinks: true)
        let html = result.htmlContent ?? ""
        XCTAssertTrue(html.contains("href=\"https://example.com/path?q=1\""),
                      "https URL must survive sanitize_links allowlist; got: \(html)")
        XCTAssertTrue(html.contains(">example</a>"),
                      "anchor wrap must be preserved for safe scheme; got: \(html)")
    }

    func testRenderBody_markdown_sanitizeLinksOn_preservesMailtoAndTel() throws {
        let mailto = try renderBody("[mail](mailto:foo@example.com)", format: .markdown, sanitizeLinks: true)
        XCTAssertTrue(mailto.htmlContent!.contains("href=\"mailto:foo@example.com\""),
                      "mailto: must survive allowlist")
        let tel = try renderBody("[call](tel:+15551234)", format: .markdown, sanitizeLinks: true)
        XCTAssertTrue(tel.htmlContent!.contains("href=\"tel:+15551234\""),
                      "tel: must survive allowlist")
    }

    func testRenderBody_markdown_sanitizeLinksOn_blocksDataURL() throws {
        // data: URLs can carry inline images / scripts — explicit block
        // even though some clients accept them. Issue #19 lists data:
        // alongside javascript: as unsafe schemes.
        let result = try renderBody("[img](data:text/html,<script>alert(1)</script>)", format: .markdown, sanitizeLinks: true)
        let html = result.htmlContent ?? ""
        XCTAssertFalse(html.contains("data:"),
                       "data: URL must NOT survive sanitize_links allowlist; got: \(html)")
    }

    // MARK: - Scenario (#87 Item 1): Allowlist tripwire — pin exact contents

    func testMessageCompositionSafeURLSchemes_exactContents() {
        // Tripwires accidental allowlist expansion. A future PR adding
        // `vbscript`, `file`, `chrome`, etc. to the set would silently
        // unblock those schemes (the existing per-bypass tests only
        // exercise canonical attacks). This test fails immediately on
        // any change to the allowlist — forcing a deliberate decision
        // with audit trail. See #87 (cluster A verify DA-4 follow-up).
        XCTAssertEqual(messageCompositionSafeURLSchemes,
                       Set(["http", "https", "mailto", "tel"]),
                       "allowlist contents changed — was this deliberate? Schemes outside this set MUST stay blocked under sanitize_links=true.")
    }

    // MARK: - Scenario (#87 Item 2): Bypass-class regression tests

    func testRenderBody_markdown_sanitizeLinksOn_blocksCaseMixedJavaScript() throws {
        // Defense relies on `.lowercased()` normalization at MarkdownRendering.swift:174.
        // A regression removing it would silently unblock case-mixed bypasses.
        let result = try renderBody("[click](JaVaScRiPt:alert(1))", format: .markdown, sanitizeLinks: true)
        let html = result.htmlContent ?? ""
        XCTAssertFalse(html.lowercased().contains("javascript:"),
                       "case-mixed JaVaScRiPt: URL must NOT survive allowlist; got: \(html)")
    }

    func testRenderBody_markdown_sanitizeLinksOn_blocksFileURL() throws {
        // file:// URLs can disclose local files via mail client interpretation.
        // Not in allowlist; must be blocked.
        let result = try renderBody("[leak](file:///etc/passwd)", format: .markdown, sanitizeLinks: true)
        let html = result.htmlContent ?? ""
        XCTAssertFalse(html.contains("file:"),
                       "file:// URL must NOT survive allowlist; got: \(html)")
    }

    func testRenderBody_markdown_sanitizeLinksOn_blocksVBScriptURL() throws {
        // Legacy IE attack vector. Not in allowlist.
        let result = try renderBody("[click](vbscript:msgbox(1))", format: .markdown, sanitizeLinks: true)
        let html = result.htmlContent ?? ""
        XCTAssertFalse(html.contains("vbscript:"),
                       "vbscript: URL must NOT survive allowlist; got: \(html)")
    }

    func testRenderBody_markdown_sanitizeLinksOn_blocksChromeURL() throws {
        // chrome:// triggers internal browser pages — not appropriate in email content.
        let result = try renderBody("[settings](chrome://flags/)", format: .markdown, sanitizeLinks: true)
        let html = result.htmlContent ?? ""
        XCTAssertFalse(html.contains("chrome:"),
                       "chrome:// URL must NOT survive allowlist; got: \(html)")
    }

    func testRenderBody_markdown_sanitizeLinksOn_blocksBlobURL() throws {
        // blob: URLs reference in-memory objects — useless and risky in email.
        let result = try renderBody("[file](blob:https://evil.example/abc-123)", format: .markdown, sanitizeLinks: true)
        let html = result.htmlContent ?? ""
        XCTAssertFalse(html.contains("blob:"),
                       "blob: URL must NOT survive allowlist; got: \(html)")
    }

    func testRenderBody_markdown_sanitizeLinksOn_blocksRelativeAndEmptyURLs() throws {
        // Empty / relative URLs lack a scheme → scheme=empty → not in allowlist
        // → anchor dropped. This is documented expected behavior (#87 Item 4 doc).
        let relativeResult = try renderBody("[home](/relative/path)", format: .markdown, sanitizeLinks: true)
        let relHtml = relativeResult.htmlContent ?? ""
        XCTAssertFalse(relHtml.contains("<a "),
                       "non-absolute URLs must have anchor dropped under sanitize_links=true; got: \(relHtml)")
        let emptyResult = try renderBody("[text]()", format: .markdown, sanitizeLinks: true)
        let emptyHtml = emptyResult.htmlContent ?? ""
        XCTAssertFalse(emptyHtml.contains("<a "),
                       "empty URLs must have anchor dropped under sanitize_links=true; got: \(emptyHtml)")
    }

    // MARK: - Scenario (#22 Item D): code block language hint

    func testRenderBody_markdown_codeBlockWithLanguageHint_emitsClassAttribute() throws {
        // ` ```swift\nlet x = 1\n``` ` should emit
        // `<pre><code class="language-swift">let x = 1\n</code></pre>` —
        // CommonMark recommended pattern, honored by Prism / Pygments /
        // highlight.js / mail clients with syntax-highlight plugins.
        let result = try renderBody("```swift\nlet x = 1\n```", format: .markdown)
        let html = result.htmlContent ?? ""
        XCTAssertTrue(html.contains("class=\"language-swift\""),
                      "code block with language hint MUST emit class=\"language-swift\"; got: \(html)")
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">"),
                      "class attribute MUST be on the inner <code> element; got: \(html)")
        XCTAssertTrue(html.contains("let x = 1"),
                      "code body must be preserved; got: \(html)")
    }

    func testRenderBody_markdown_codeBlockWithoutLanguage_omitsClassAttribute() throws {
        // ` ```\nplain code\n``` ` (no language tag) keeps the original
        // `<pre><code>...` form without class attribute (#22 Item D
        // backwards compat — fences without language stay byte-identical).
        let result = try renderBody("```\nplain code\n```", format: .markdown)
        let html = result.htmlContent ?? ""
        XCTAssertTrue(html.contains("<pre><code>"),
                      "fence without language tag MUST emit plain <pre><code> (no class); got: \(html)")
        XCTAssertFalse(html.contains("class=\"language-"),
                       "fence without language tag MUST NOT emit a language class; got: \(html)")
        XCTAssertTrue(html.contains("plain code"),
                      "code body must be preserved; got: \(html)")
    }

    // MARK: - Scenario (#16): nested list rendering

    func testRenderBody_markdown_nestedUnorderedList_twoLevels() throws {
        // Canonical case from #15 DA #2 reproducer: inner list was previously
        // collapsed into outer (`<ul><li>OuterInner</li></ul>`). Post-#16 must
        // emit proper `<ul><li>Outer<ul><li>Inner</li></ul></li></ul>` shape.
        let result = try renderBody("- Outer\n  - Inner", format: .markdown)
        let html = result.htmlContent ?? ""
        // Two distinct <ul> opens (outer + inner)
        let ulOpenCount = html.components(separatedBy: "<ul>").count - 1
        XCTAssertEqual(ulOpenCount, 2, "nested unordered list MUST emit 2 <ul> opens; got HTML: \(html)")
        let ulCloseCount = html.components(separatedBy: "</ul>").count - 1
        XCTAssertEqual(ulCloseCount, 2, "nested unordered list MUST emit 2 </ul> closes; got HTML: \(html)")
        // Both Outer and Inner text appear as separate <li> items
        XCTAssertTrue(html.contains("Outer"), "outer item text must be preserved")
        XCTAssertTrue(html.contains("Inner"), "inner item text must be preserved")
        // Inner must be inside (after) outer's <li>
        guard let outerIdx = html.range(of: "Outer")?.lowerBound,
              let innerIdx = html.range(of: "Inner")?.lowerBound else {
            XCTFail("missing required tokens")
            return
        }
        XCTAssertLessThan(outerIdx, innerIdx, "outer item must appear before inner")
    }

    func testRenderBody_markdown_nestedOrderedList_twoLevels() throws {
        let result = try renderBody("1. Outer\n   1. Inner", format: .markdown)
        let html = result.htmlContent ?? ""
        let olOpenCount = html.components(separatedBy: "<ol>").count - 1
        XCTAssertEqual(olOpenCount, 2, "nested ordered list MUST emit 2 <ol> opens; got HTML: \(html)")
        let olCloseCount = html.components(separatedBy: "</ol>").count - 1
        XCTAssertEqual(olCloseCount, 2, "nested ordered list MUST emit 2 </ol> closes; got HTML: \(html)")
        XCTAssertTrue(html.contains("Outer"))
        XCTAssertTrue(html.contains("Inner"))
    }

    func testRenderBody_markdown_mixedNesting_unorderedOuterOrderedInner() throws {
        // Mixed nesting: unordered outer + ordered inner. Both list types
        // must open + close their own elements at the right depths.
        let result = try renderBody("- A\n  1. B", format: .markdown)
        let html = result.htmlContent ?? ""
        XCTAssertTrue(html.contains("<ul>"), "outer unordered list opened; got: \(html)")
        XCTAssertTrue(html.contains("</ul>"), "outer unordered list closed; got: \(html)")
        XCTAssertTrue(html.contains("<ol>"), "inner ordered list opened; got: \(html)")
        XCTAssertTrue(html.contains("</ol>"), "inner ordered list closed; got: \(html)")
        // Inner <ol> must come BEFORE outer </ul> (i.e. nested inside)
        guard let olOpen = html.range(of: "<ol>")?.lowerBound,
              let ulClose = html.range(of: "</ul>")?.lowerBound else {
            XCTFail("missing required tokens")
            return
        }
        XCTAssertLessThan(olOpen, ulClose, "inner <ol> must open BEFORE outer </ul> (nested, not sibling)")
    }

    func testRenderBody_markdown_threeLevelNesting() throws {
        let result = try renderBody("- A\n  - B\n    - C", format: .markdown)
        let html = result.htmlContent ?? ""
        let ulOpenCount = html.components(separatedBy: "<ul>").count - 1
        XCTAssertEqual(ulOpenCount, 3, "three-level nested list MUST emit 3 <ul> opens; got HTML: \(html)")
        let ulCloseCount = html.components(separatedBy: "</ul>").count - 1
        XCTAssertEqual(ulCloseCount, 3, "three-level nested list MUST emit 3 </ul> closes; got HTML: \(html)")
        for token in ["A", "B", "C"] {
            XCTAssertTrue(html.contains(token), "expected token '\(token)' preserved; got: \(html)")
        }
    }

    func testRenderBody_markdown_listExit_closesAllLists() throws {
        // After a nested list, a paragraph block must close ALL open lists,
        // not just the innermost. Otherwise we'd leak `<ul>` opens.
        let result = try renderBody("- A\n  - B\n\nParagraph after.", format: .markdown)
        let html = result.htmlContent ?? ""
        let ulOpenCount = html.components(separatedBy: "<ul>").count - 1
        let ulCloseCount = html.components(separatedBy: "</ul>").count - 1
        XCTAssertEqual(ulOpenCount, ulCloseCount,
                       "list opens and closes MUST balance after exit; got opens=\(ulOpenCount) closes=\(ulCloseCount); HTML: \(html)")
        XCTAssertTrue(html.contains("<p>Paragraph after.</p>"),
                      "paragraph after nested list MUST render as own <p>; got: \(html)")
    }

    func testRenderBody_markdown_flatList_backwardsCompatRegressionBaseline() throws {
        // #16 backwards-compat: a flat (depth-1) list must render byte-identical
        // to pre-refactor output. This pins the regression baseline so future
        // changes to the nesting state machine can't silently break flat lists.
        let result = try renderBody("- A\n- B", format: .markdown)
        let html = result.htmlContent ?? ""
        let ulOpenCount = html.components(separatedBy: "<ul>").count - 1
        XCTAssertEqual(ulOpenCount, 1, "flat list MUST emit exactly 1 <ul> open; got HTML: \(html)")
        let liCount = html.components(separatedBy: "<li>").count - 1
        XCTAssertEqual(liCount, 2, "flat 2-item list MUST emit 2 <li>; got HTML: \(html)")
    }

    // MARK: - Scenario (#17): markdown table rendering

    func testRenderBody_markdown_basicTable_emitsHeadAndBody() throws {
        // Canonical #15 DA-5 reproducer. Pre-#17 collapsed to `<p>ab12</p>`.
        // Post-#17: proper <table><thead><tr><th>...</th></tr></thead><tbody>
        // <tr><td>...</td></tr></tbody></table>.
        let md = "| a | b |\n|---|---|\n| 1 | 2 |"
        let result = try renderBody(md, format: .markdown)
        let html = result.htmlContent ?? ""
        XCTAssertTrue(html.contains("<table>"), "table MUST emit <table>; got: \(html)")
        XCTAssertTrue(html.contains("<thead>"), "table MUST emit <thead> for header row; got: \(html)")
        XCTAssertTrue(html.contains("<tbody>"), "table MUST emit <tbody> for data rows; got: \(html)")
        XCTAssertTrue(html.contains("<th"), "header cells MUST emit <th>; got: \(html)")
        XCTAssertTrue(html.contains("<td"), "data cells MUST emit <td>; got: \(html)")
        XCTAssertTrue(html.contains("</table>"), "table MUST close </table>; got: \(html)")
        // All 4 cell values present
        for token in ["a", "b", "1", "2"] {
            XCTAssertTrue(html.contains(token), "cell content '\(token)' must be preserved; got: \(html)")
        }
    }

    func testRenderBody_markdown_tableWithAlignments_emitsStyleAttr() throws {
        // `:---` = left (default, no style), `:---:` = center, `---:` = right.
        // Left columns emit no `style` attr (browser default).
        let md = """
        | L | C | R |
        |:--|:-:|--:|
        | a | b | c |
        """
        let result = try renderBody(md, format: .markdown)
        let html = result.htmlContent ?? ""
        // Left col: no style attribute
        XCTAssertFalse(html.contains("style=\"text-align: left\""),
                       "left alignment MUST NOT emit a style attribute (browser default); got: \(html)")
        // Center col: emits style
        XCTAssertTrue(html.contains("style=\"text-align: center\""),
                      "center alignment MUST emit style=\"text-align: center\"; got: \(html)")
        // Right col: emits style
        XCTAssertTrue(html.contains("style=\"text-align: right\""),
                      "right alignment MUST emit style=\"text-align: right\"; got: \(html)")
    }

    func testRenderBody_markdown_tableExit_closesTableTags() throws {
        // After a table, a paragraph block MUST close the table cleanly,
        // not leave `<table>` / `<tbody>` / `<tr>` dangling.
        let md = """
        | x | y |
        |---|---|
        | 1 | 2 |

        After.
        """
        let result = try renderBody(md, format: .markdown)
        let html = result.htmlContent ?? ""
        let openCount = html.components(separatedBy: "<table>").count - 1
        let closeCount = html.components(separatedBy: "</table>").count - 1
        XCTAssertEqual(openCount, closeCount,
                       "table opens and closes MUST balance; got opens=\(openCount) closes=\(closeCount); HTML: \(html)")
        XCTAssertTrue(html.contains("<p>After.</p>"),
                      "paragraph after table MUST render as own <p>; got: \(html)")
    }

    func testRenderBody_markdown_tableWithMultipleDataRows() throws {
        // Two data rows means we need to emit </tr><tr> between them.
        let md = """
        | h |
        |---|
        | 1 |
        | 2 |
        """
        let result = try renderBody(md, format: .markdown)
        let html = result.htmlContent ?? ""
        // Should have 3 <tr> opens total: header + 2 data rows
        let trCount = html.components(separatedBy: "<tr>").count - 1
        XCTAssertEqual(trCount, 3, "multi-row table MUST emit 3 <tr> opens (1 header + 2 data); got HTML: \(html)")
    }
}
