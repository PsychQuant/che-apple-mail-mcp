import XCTest

/// #537 — source-shape guard for how `Server` gets its Envelope Index reader.
///
/// The unit tests cover `IndexReaderProvider` and `FDACheckReport` in isolation,
/// but a `Server` instance cannot be built in a unit test, so nothing there
/// would notice if the wiring slipped back to the old shape: a reader built once
/// in `init` and stored in a `let`, and a `check_fda` that never asks the reader
/// anything. This is a structural check only. It cannot see every way to
/// bypass the provider (a second reader built elsewhere, say), and passing it is
/// not evidence that the retry works; that evidence is the provider tests.
final class IndexReaderWiringGuardTests: XCTestCase {

    private func serverSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <package root>/
            .appendingPathComponent("Sources/CheAppleMailMCP/Server.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text of the `case "check_fda":` branch, up to the next `case "`.
    private func checkFdaBranch(_ source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "case \"check_fda\":"), "check_fda branch not found")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n        case \"")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    func testCheckFdaRetriesTheReaderAndReportsItsState() throws {
        let branch = try checkFdaBranch(try serverSource())
        XCTAssertTrue(branch.contains("indexProvider.forceRetry()"),
                      "check_fda must ask the server's own reader to retry, not just fopen the file (#537)")
        XCTAssertTrue(branch.contains("FDACheckReport.text("),
                      "check_fda must build its answer from the probe AND the reader outcome (#537)")
        XCTAssertFalse(branch.contains("should now work"),
                       "the unconditional promise must not come back (#537)")
    }

    func testIndexReaderIsNotAStoredPropertyAnyMore() throws {
        let source = try serverSource()
        // A stored declaration has no `{` on its line; the computed accessor does.
        let stored = try NSRegularExpression(pattern: #"(?m)^\s*(private\s+)?(let|var)\s+indexReader\b[^{\n]*$"#)
        let range = NSRange(source.startIndex..., in: source)
        XCTAssertEqual(stored.numberOfMatches(in: source, range: range), 0,
                       "indexReader must read through the provider, not hold a reader fixed at init (#537)")
        XCTAssertTrue(source.contains("var indexReader: EnvelopeIndexReader? { indexProvider.current() }"),
                      "indexReader must ask the provider each time it is used (#537)")
        XCTAssertFalse(source.contains("self.indexReader ="),
                       "init must not assign a reader directly any more (#537)")
    }
}
