import XCTest

/// #221 — source-invariant guard against the all-mailbox full-body-scan predicate.
///
/// `messages ... whose content contains "<x>"` is an O(corpus) AppleScript
/// predicate: Mail must deserialize EVERY message body to test it, so on a large
/// (~80k-email) mailbox it exhausts memory and OOM-crashes Mail.app — the exact
/// incident the #218 spike hit (filed as #221).
///
/// The shipped read paths already avoid it: `search_emails` uses
/// `whose subject contains … or sender contains …` (subject/sender only, never
/// `content`). This test pins that invariant: it scans the shipped Swift sources
/// and FAILS LOUDLY if any future read path (or a copy-pasted AppleScript snippet)
/// reintroduces `whose content contains`. The safe alternatives are subject-match,
/// scoping to a specific (small) special mailbox, or reading a single message's
/// `content` after locating it by id — none of which force an all-corpus body load.
///
/// Note this targets the *predicate* `whose content contains` specifically, NOT a
/// bare `content` read: `content:` properties, `set html content`, and bounded
/// per-message `content of m` reads over a small mailbox are all legitimate and
/// must not trip the guard.
final class NoContentContainsScanGuardTests: XCTestCase {

    /// The shipped Swift sources directory, derived from this test file's own path
    /// (`Tests/CheAppleMailMCPTests/<this>.swift` → package root → `Sources/...`).
    private func shippedSourcesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <package root>/
            .appendingPathComponent("Sources/CheAppleMailMCP")
    }

    /// Scan a sources tree for `needle`, returning `file:line: text` offenders.
    private func offenders(in dir: URL, matching needle: String) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var hits: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for (idx, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(needle) {
                hits.append("\(url.lastPathComponent):\(idx + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return hits.sorted()
    }

    func testShippedSourcesHaveNoWholeContentContainsPredicate() throws {
        let sources = shippedSourcesDir()
        // Sanity: the sources dir must exist (guards against a path-derivation regression
        // that would make the test vacuously pass).
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: sources.path, isDirectory: &isDir) && isDir.boolValue,
                      "could not locate Sources/CheAppleMailMCP at \(sources.path) — path derivation broke")

        let hits = try offenders(in: sources, matching: "whose content contains")
        XCTAssertTrue(hits.isEmpty, """
            A shipped read path uses the O(corpus) `whose content contains` AppleScript predicate, \
            which OOM-crashes Mail.app on a large mailbox (#221/#218). Replace it with a subject/sender \
            match, or scope to a specific small mailbox, or read a single message's content after locating \
            it by id. Offenders:
            \(hits.joined(separator: "\n"))
            """)
    }
}
