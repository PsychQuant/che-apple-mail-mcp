import XCTest
@testable import CheAppleMailMCP

/// #490 — guard tests for `.claude/rules/direct-write-transaction-safety.md`.
/// Each test pins one guarantee of that rule so that a speed change which
/// weakens it turns the suite red instead of shipping silently.
///
/// - Item 8: the gap between the two read toggles of the upload trigger is a
///   measured safety margin (0.5 s, from the #463 Round 2 supplement, runs I3
///   and I4; #472 saw 0.3 s leave one of two drafts unread locally). Changing it needs the live
///   experiment of #488 first.
/// - Item 7: after an accepted trigger the path waits for the upload to be
///   confirmed and then re-asserts the draft's read status (#482). This is a
///   structural check of the source; a behavioural test needs the
///   controller/writer seam tracked in #484.
final class DirectWriteSafetyGuardTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - Item 8: the gap between the read toggles

    static let minimumToggleGap: Double = 0.5

    enum ToggleGap: Equatable {
        case seconds(Double)
        case unverifiable(String)
    }

    /// The total of the `delay` statements between the toggle to unread and
    /// the toggle back to read. A script the parser cannot read with certainty
    /// is reported as unverifiable, never as a number: a `delay` whose
    /// argument is not a plain number literal on its own line could hide any
    /// value, and a second toggle pair would make "the gap" ambiguous.
    static func toggleGap(in script: String) -> ToggleGap {
        let toUnread = ranges(of: "set read status of _m to false", in: script)
        let toRead = ranges(of: "set read status of _m to true", in: script)
        guard toUnread.count == 1, toRead.count == 1 else {
            return .unverifiable("expected one toggle to unread and one back to read, "
                                 + "found \(toUnread.count) and \(toRead.count)")
        }
        guard toUnread[0].upperBound <= toRead[0].lowerBound else {
            return .unverifiable("the toggle back to read comes before the toggle to unread")
        }
        let between = String(script[toUnread[0].upperBound..<toRead[0].lowerBound])
        let delayCount = matches(of: #"\bdelay\b"#, in: between).count
        let literals = matches(of: #"^\s*delay\s+([0-9]+(?:\.[0-9]+)?)\s*(?:--.*)?$"#, in: between)
            .compactMap { Double($0) }
        guard delayCount == literals.count else {
            return .unverifiable("a delay between the toggles is not a plain number literal on its own line")
        }
        return .seconds(literals.reduce(0, +))
    }

    func testTriggerScriptKeepsTheMeasuredGapBetweenItsReadToggles() {
        let script = buildDirectDraftTriggerScript(rowId: 305619)
        switch Self.toggleGap(in: script) {
        case .seconds(let gap):
            XCTAssertGreaterThanOrEqual(
                gap, Self.minimumToggleGap,
                "rule item 8: the read-toggle gap is a measured margin (#463 Round 2 supplement; #472 saw 0.3 s leave a draft "
                + "unread locally). Shortening it needs the #488 live experiment, at least 10 runs per value.")
        case .unverifiable(let why):
            XCTFail("rule item 8: the trigger script's read-toggle gap cannot be verified: \(why)")
        }
    }

    /// The parser reads what it claims to: each counter-example is a script
    /// whose gap is too short, or hidden, and must not pass.
    func testToggleGapParserRejectsShortOrHiddenGaps() {
        func script(_ middle: String, before: String = "") -> String {
            "tell application \"Mail\"\n\(before)    set read status of _m to false\n\(middle)"
                + "    set read status of _m to true\nend tell\n"
        }
        XCTAssertEqual(Self.toggleGap(in: script("    delay 0.5\n")), .seconds(0.5))
        XCTAssertEqual(Self.toggleGap(in: script("    delay 0.5 -- the #463 gap\n")), .seconds(0.5))
        XCTAssertEqual(Self.toggleGap(in: script("    delay 0.3\n")), .seconds(0.3), "the gap #472 saw fail")
        XCTAssertEqual(Self.toggleGap(in: script("    delay 0.2\n    log \"x\"\n    delay 0.2\n")), .seconds(0.4),
                       "split delays are summed")
        XCTAssertEqual(Self.toggleGap(in: script("", before: "    delay 0.5\n")), .seconds(0),
                       "a delay outside the toggles does not count")
        for hidden in ["    delay gapSeconds\n", "    delay (0.5)\n", "    delay 1 / 4\n"] {
            guard case .unverifiable = Self.toggleGap(in: script(hidden)) else {
                return XCTFail("a non-literal delay must be unverifiable: \(hidden)")
            }
        }
        let twoPairs = script("    delay 0.5\n") + script("    delay 0.1\n")
        guard case .unverifiable = Self.toggleGap(in: twoPairs) else {
            return XCTFail("two toggle pairs make the gap ambiguous")
        }
    }

    // MARK: - Item 7: upload confirmation and read repair

    func testUploadWaitIsNotShortened() {
        XCTAssertGreaterThanOrEqual(
            DirectDraftPath(controller: MailController.shared, reader: nil).uploadDeadline, 10,
            "rule item 7: the upload wait is what finds a draft that did not upload and what lets the read repair "
            + "run. A shorter wait is a speed change: bring the upload-confirm time distribution first.")
    }

    func testUploadIsConfirmedThenReadRepairedAfterAnAcceptedTrigger() throws {
        let file = Self.repoRoot.appendingPathComponent("Sources/CheAppleMailMCP/DirectDraft/DirectDraftPath.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let hint = " (if a refactor moved this, replace the check with a behavioural test once #484 adds the seam)"

        // After the trigger succeeds: wait loop → upload state → uploaded → read repair, in this order.
        let sequence = ["timer.mark(\"trigger_sent\")", "< uploadDeadline", "writer.uploadState(inserted)",
                        "timer.mark(\"uploaded\")", "await ensureRead(writer, inserted)"]
        var cursor = source.startIndex
        var found: [Range<String.Index>] = []
        for marker in sequence {
            guard let range = source.range(of: marker, range: cursor..<source.endIndex) else {
                return XCTFail("rule item 7: `\(marker)` not found after `\(found.isEmpty ? "start" : sequence[found.count - 1])`" + hint)
            }
            found.append(range)
            cursor = range.upperBound
        }

        // Nothing between the accepted trigger and the wait loop may report the draft as created.
        let beforeWait = String(source[found[0].upperBound..<found[1].lowerBound])
        XCTAssertFalse(beforeWait.contains(".created("),
                       "rule items 6/7: a result is returned before the upload wait" + hint)

        // The read repair re-asserts read status when the draft still shows unread.
        let start = try XCTUnwrap(source.range(of: "private func ensureRead("), "ensureRead not found" + hint)
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains(".stillUnread") && body.contains("controller.markDirectDraftRead("),
                      "rule item 7 (#482): ensureRead must re-assert read status when the draft shows unread" + hint)
    }

    // MARK: - Helpers

    private static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var cursor = text.startIndex
        while let range = text.range(of: needle, range: cursor..<text.endIndex) {
            result.append(range)
            cursor = range.upperBound
        }
        return result
    }

    /// The first capture group of each match, or the whole match when the
    /// pattern has no group.
    private static func matches(of pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            ns.substring(with: match.numberOfRanges > 1 ? match.range(at: 1) : match.range)
        }
    }
}
