import XCTest

/// #346 — source-invariant guard: **no non-throwing writes to stderr**.
///
/// `FileHandle.standardError.write(_:)` raises an **uncatchable Objective-C
/// exception** when the descriptor errors — `SIGABRT`, exit 134 (verified by
/// #303 on the real binary). Since #320 ignores `SIGPIPE` process-wide, a
/// broken-pipe write no longer dies by signal 13; it returns `EPIPE`, which
/// this API then converts into that same uncatchable abort. So the non-throwing
/// call is not merely inelegant — it is the remaining way a host closing its
/// stderr read end can kill this server.
///
/// The reason this needs a *guard* and not just a fix: #303 converted exactly
/// one site and left 26, and #320's CHANGELOG then described the whole server
/// as safe ("the throwing stderr writes swallow it") while 26 of 27 writers
/// were not throwing. Nothing in the build or the test suite noticed. A count
/// that drifted once will drift again — the 27th writer is one autocomplete
/// away, and it will look exactly like the code beside it.
///
/// Every diagnostic must go through `Diagnostics.emit`, which uses the throwing
/// `write(contentsOf:)` and reports delivery instead of aborting.
final class NoNonThrowingStderrWriteGuardTests: XCTestCase {

    private func shippedSourcesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <package root>/
            .appendingPathComponent("Sources")
    }

    func testNoSourceFileUsesTheNonThrowingStderrWrite() throws {
        let fm = FileManager.default
        let dir = shippedSourcesDir()
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return XCTFail("could not enumerate \(dir.path)")
        }

        // The exact shape that aborts. `write(contentsOf:)` is the throwing
        // API and is deliberately NOT matched.
        let needle = "standardError.write(Data("
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for (idx, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains(needle) {
                // Skip prose: a doc comment naming the banned call (this file's
                // own rationale, or #320's note in main.swift) is not a call.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") {
                    continue
                }
                offenders.append("\(url.lastPathComponent):\(idx + 1): \(trimmed)")
            }
        }

        XCTAssertTrue(offenders.isEmpty,
            "non-throwing stderr write(s) found — these abort the process (SIGABRT) on a "
            + "broken pipe instead of returning an error (#346). Use Diagnostics.emit:\n"
            + offenders.joined(separator: "\n"))
    }

    /// The counterpart: the sink must still exist and be used. A guard that only
    /// forbids the old call would also pass on a tree with no diagnostics at all.
    func testDiagnosticsSinkIsPresentAndUsed() throws {
        let dir = shippedSourcesDir()
        let sink = dir.appendingPathComponent("CheAppleMailMCP/Diagnostics.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sink.path),
                      "Diagnostics.swift is the single stderr sink — it must exist")
        XCTAssertTrue(
            (try String(contentsOf: sink, encoding: .utf8)).contains("write(contentsOf:"),
            "the sink must use the THROWING write — that is the entire point")

        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return XCTFail("could not enumerate \(dir.path)")
        }
        var callSites = 0
        for case let url as URL in walker where url.pathExtension == "swift"
        && url.lastPathComponent != "Diagnostics.swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            callSites += text.components(separatedBy: "Diagnostics.emit(").count - 1
        }
        XCTAssertGreaterThanOrEqual(callSites, 20,
            "expected the ~26 converted diagnostics to route through the sink; found \(callSites). "
            + "A sharp drop means sites were deleted or routed somewhere else, not that the "
            + "server stopped needing diagnostics.")
    }
}
