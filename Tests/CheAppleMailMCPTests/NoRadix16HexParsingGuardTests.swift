import XCTest

/// #641 — source-invariant guard. `UInt8(hex, radix: 16)` accepts a leading sign
/// (`UInt8("+5", radix: 16)` is 5), so a quoted-printable or percent escape read
/// that way turns `=+5` into a control byte. Read a two-character escape through
/// `HexEscape.byte(_:_:)` in `Sources/MailSQLite/`, which takes ASCII hex digits only.
///
/// This is a text scan of code lines (a `//` comment may name the call): it fails
/// on the spelling below, not on a radix passed through a variable.
final class NoRadix16HexParsingGuardTests: XCTestCase {

    private func sourcesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <package root>/
            .appendingPathComponent("Sources")
    }

    func testNoSourceParsesAnEscapeWithRadix16() throws {
        let dir = sourcesDir()
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return XCTFail("could not enumerate \(dir.path)")
        }
        var scanned = 0
        var hits: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for (idx, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                if code.contains("radix: 16") { hits.append("\(url.lastPathComponent):\(idx + 1)") }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan did not find the sources")
        XCTAssertEqual(hits, [], "read a hex escape through HexEscape.byte (#641)")
    }

    func testTheScanSeesTheSpellingItForbids() {
        // The scan's own predicate, on a planted line: it must flag the real spelling and ignore a comment.
        func flagged(_ line: String) -> Bool { (line.components(separatedBy: "//").first ?? line).contains("radix: 16") }
        XCTAssertTrue(flagged("if let byte = UInt8(hex, radix: 16) {"))
        XCTAssertFalse(flagged("// UInt8(hex, radix: 16) accepts a sign"))
    }
}
