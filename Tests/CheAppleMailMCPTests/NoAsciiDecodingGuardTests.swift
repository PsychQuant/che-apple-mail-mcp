import XCTest

/// #561 — source-invariant guard. `String(data:encoding: .ascii)` behaves
/// differently in the shipped binary (stamped sdk 13.0: it succeeds and maps
/// each byte to a Latin-1 scalar) and under `swift test` (the `xctest` host:
/// it returns `nil`), so a call site's behaviour cannot be tested here. Decode
/// through `ByteDecoding` in `Sources/MailSQLite/` instead, which says which of
/// the two it means.
///
/// This scan reads code lines only (a `//` comment may name the call).
final class NoAsciiDecodingGuardTests: XCTestCase {

    private func sourcesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <package root>/
            .appendingPathComponent("Sources")
    }

    func testNoSourceDecodesThroughTheASCIIEncoding() throws {
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
                if code.contains("encoding: .ascii") {
                    hits.append("\(url.lastPathComponent):\(idx + 1)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan did not find the sources")
        XCTAssertEqual(hits, [], "decode through ByteDecoding instead (#561)")
    }
}
