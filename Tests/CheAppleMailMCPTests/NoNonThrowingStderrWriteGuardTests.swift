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

    /// Two bans, both scanned over the WHOLE file text rather than line by line.
    ///
    /// Line-by-line matching of one adjacent literal was the first version, and
    /// verify round 1 walked straight through it: a call split across lines
    /// (`FileHandle.standardError.write(` then `Data(...)` on the next) left
    /// `offenders` empty, so "the 27th writer fails the build" was not true.
    /// Binding the handle to a variable first evaded it just as easily.
    ///
    /// **Ban 1** — any `standardError.write(` that is not `write(contentsOf:`,
    /// whitespace- and newline-tolerant.
    /// **Ban 2** — binding `FileHandle.standardError` to a variable outside the
    /// sink, which is the other way to reach the non-throwing overload.
    ///
    /// Deliberately **comment-agnostic**: no attempt is made to skip `//` lines.
    /// Stripping comments needs a Swift lexer to avoid mangling `https://` in a
    /// string literal, and a guard that can be defeated by appending a comment
    /// is not a guard. The cost is that prose must not spell the banned call
    /// form — the three doc comments that did were reworded to say
    /// "the non-throwing `write` overload on `FileHandle.standardError`".
    func testNoSourceFileUsesTheNonThrowingStderrWrite() throws {
        let banned = try NSRegularExpression(
            pattern: #"standardError\s*\.\s*write\s*\(\s*(?!contentsOf)"#)
        let binding = try NSRegularExpression(
            pattern: #"(let|var)\s+\w+\s*(:[^=\n]+)?=\s*FileHandle\s*\.\s*standardError\b"#)

        var offenders: [String] = []
        for url in try swiftFiles() {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let range = NSRange(text.startIndex..., in: text)

            for m in banned.matches(in: text, range: range) {
                offenders.append("\(url.lastPathComponent):\(line(of: m.range, in: text)): "
                                 + "non-throwing stderr write")
            }
            // The sink is the one place allowed to hold the handle.
            guard url.lastPathComponent != "Diagnostics.swift" else { continue }
            for m in binding.matches(in: text, range: range) {
                offenders.append("\(url.lastPathComponent):\(line(of: m.range, in: text)): "
                                 + "FileHandle.standardError bound to a variable — route through "
                                 + "Diagnostics.emit instead")
            }
        }

        XCTAssertTrue(offenders.isEmpty,
            "these abort the process (SIGABRT) on a broken pipe instead of returning an "
            + "error (#346). Use Diagnostics.emit:\n" + offenders.joined(separator: "\n"))
    }

    private func swiftFiles() throws -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: shippedSourcesDir(), includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func line(of range: NSRange, in text: String) -> Int {
        guard let r = Range(range, in: text) else { return 0 }
        return text[text.startIndex..<r.lowerBound].filter { $0 == "\n" }.count + 1
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

        // Per-file floors, not one global count. Verify round 1's objection to a
        // single `>= 20` was fair: with 27 present you could delete any seven
        // real diagnostics and still pass. Per-file floors at least localize a
        // wholesale loss — deleting Export's only diagnostic, or gutting
        // MailController's, now fails where a global floor absorbed it.
        //
        // Stated plainly: this is a smoke check against bulk deletion, NOT a
        // completeness proof. Nothing here can tell that a specific diagnostic
        // still fires; the ban above is the invariant that actually holds.
        // MailController's floor dropped 5 → 4 with #304. The four diagnostics
        // removed there all announced the same thing — "falling back to the
        // legacy AppleScript injection path" — and that path no longer exists.
        // A refusal reaches the caller as an error, so it needs no stderr echo;
        // the silent fallback those warns existed to expose is what was deleted.
        let floors = [("Server.swift", 15), ("MailController.swift", 4),
                      ("ExportEmailsMarkdown.swift", 1)]
        for (name, floor) in floors {
            let hits = try swiftFiles()
                .filter { $0.lastPathComponent == name }
                .map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }
                .map { $0.components(separatedBy: "Diagnostics.emit(").count - 1 }
                .reduce(0, +)
            XCTAssertGreaterThanOrEqual(hits, floor,
                "\(name) routes \(hits) diagnostics through the sink, expected ≥ \(floor) — "
                + "a drop this large means sites were deleted or re-routed, not that the server "
                + "stopped needing diagnostics")
        }
    }
}
