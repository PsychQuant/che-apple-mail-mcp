import XCTest
@testable import CheAppleMailMCP

/// #465 — task 3.3: "Honest status and coverage reporting".
final class HonestStatusTests: XCTestCase {

    private func run(_ source: FakeLogSource, _ query: MailLogQuery = Synthetic.query()) -> [String: Any] {
        MailLogService(source: source, timeZone: Synthetic.taipei).run(query)
    }

    func testEmptyWindow() {
        let r = run(FakeLogSource())
        XCTAssertEqual(r["status"] as? String, "no_events_in_window")
        XCTAssertEqual(r["returned"] as? Int, 0)
        XCTAssertEqual(Synthetic.results(r).count, 0)
        let notice = r["notice"] as? String ?? ""
        XCTAssertTrue(notice.contains("absence of log lines"), notice)
        XCTAssertTrue(notice.contains("does not establish"), notice)
    }

    func testReaderExitsWithAnError() {
        let stderr = String(repeating: "e", count: 1000)
        let r = run(FakeLogSource(end: .exhausted(exitStatus: 64, stderrTail: stderr)))
        XCTAssertEqual(r["status"] as? String, "unavailable")
        XCTAssertEqual(r["reason"] as? String, "nonzero_exit")
        XCTAssertEqual((r["reason_detail"] as? String)?.count, 300, "at most 300 characters of the reader's own stderr")
        XCTAssertEqual(r["returned"] as? Int, 0)
        XCTAssertEqual(Synthetic.results(r).count, 0)
    }

    func testDeadlineAfterPartialRead_returnsWhatWasRead() {
        let source = FakeLogSource(lines: (0..<5).map { Synthetic.line(offset: Double($0)) }, end: .deadline)
        let r = run(source)
        XCTAssertEqual(r["status"] as? String, "ok")
        XCTAssertEqual(r["returned"] as? Int, 5)
        XCTAssertEqual(r["stopped_by"] as? String, "deadline")
        XCTAssertEqual(r["truncated"] as? Bool, true)
        XCTAssertEqual(r["next_start"] as? String, Synthetic.iso(4))
        XCTAssertEqual(r["next_offset"] as? Int, 1)
    }

    func testDeadlineWithNothingRead_isUnavailable_notEmpty() {
        let r = run(FakeLogSource(end: .deadline))
        XCTAssertEqual(r["status"] as? String, "unavailable")
        XCTAssertEqual(r["reason"] as? String, "deadline_exceeded")
    }

    func testSpawnFailure() {
        let r = run(FakeLogSource(end: .spawnFailed("could not launch /usr/bin/log: nope")))
        XCTAssertEqual(r["status"] as? String, "unavailable")
        XCTAssertEqual(r["reason"] as? String, "spawn_failed")
        XCTAssertTrue((r["reason_detail"] as? String ?? "").contains("could not launch"))
    }

    func testScanCapWithEvents_andWithout() {
        let with = run(FakeLogSource(lines: [Synthetic.line(offset: 0)], end: .scanCap))
        XCTAssertEqual(with["status"] as? String, "ok")
        XCTAssertEqual(with["stopped_by"] as? String, "scan_cap")
        XCTAssertEqual(with["truncated"] as? Bool, true)

        // Nothing in the window was reached: not an empty window (round 2, finding 14).
        let without = run(FakeLogSource(end: .scanCap))
        XCTAssertEqual(without["status"] as? String, "unavailable")
        XCTAssertEqual(without["reason"] as? String, "scan_cap_exceeded")
    }

    func testUnparseableLinesAreSkippedAndCounted_trailerIsNot() {
        let source = FakeLogSource(lines: [
            Synthetic.line(offset: 0),
            Data("this is not json".utf8),
            Synthetic.line(offset: 1),
            Data(#"{"count":2,"finished":1}"#.utf8),
        ])
        let r = run(source)
        XCTAssertEqual(r["returned"] as? Int, 2)
        XCTAssertEqual(r["skipped_lines"] as? Int, 1)
    }

    /// finding #7/#10: if Apple renames the timestamp key, every line becomes "not an event". That
    /// must read as UNAVAILABLE (we could not understand the output), never as a clean empty window.
    func testOutputThatNeverContainsARecognizableEvent_isUnavailable_notEmpty() {
        let lines = (0..<3).map { _ in Data(#"{"time":"2026-10-02 12:42:26.431000+0800","category":"X"}"#.utf8) } + [Data(#"{"count":3,"finished":1}"#.utf8)]
        let r = run(FakeLogSource(lines: lines))
        XCTAssertEqual(r["status"] as? String, "unavailable")
        XCTAssertEqual(r["reason"] as? String, "unrecognized_output")
        XCTAssertEqual(r["skipped_lines"] as? Int, 3, "the trailer is not counted, the three unrecognized lines are")
        XCTAssertTrue((r["reason_detail"] as? String ?? "").contains("format"))
    }

    func testAnOutputThatIsOnlyTheTrailer_isAnHonestEmptyWindow() {
        let r = run(FakeLogSource(lines: [Data(#"{"count":0,"finished":1}"#.utf8)]))
        XCTAssertEqual(r["status"] as? String, "no_events_in_window")
        XCTAssertEqual(r["skipped_lines"] as? Int, 0)
    }

    func testSomeUnrecognizedLinesAmongRealEvents_areCountedButDoNotMakeItUnavailable() {
        let r = run(FakeLogSource(lines: [Synthetic.line(offset: 0), Data(#"{"foo":1}"#.utf8), Synthetic.line(offset: 1)]))
        XCTAssertEqual(r["status"] as? String, "ok")
        XCTAssertEqual(r["skipped_lines"] as? Int, 1)
    }

    func testCoverageAndWindow() {
        let source = FakeLogSource(lines: [Synthetic.line(offset: 5), Synthetic.line(offset: 9)])
        let r = run(source)
        let coverage = r["coverage"] as? [String: Any]
        XCTAssertEqual(coverage?["first_event"] as? String, Synthetic.iso(5))
        XCTAssertEqual(coverage?["last_event"] as? String, Synthetic.iso(9))
        XCTAssertEqual(coverage?["source"] as? String, "log show --style ndjson")
        let window = r["window"] as? [String: Any]
        XCTAssertEqual(window?["start"] as? String, Synthetic.iso(0))
        XCTAssertEqual(window?["end"] as? String, Synthetic.iso(600))
    }

    func testCoverageIsNullWhenThereAreNoEvents() {
        let coverage = run(FakeLogSource())["coverage"] as? [String: Any]
        XCTAssertTrue(coverage?["first_event"] is NSNull)
        XCTAssertTrue(coverage?["last_event"] is NSNull)
    }

    /// The tool must never be able to say "it did not happen". Enumerate every
    /// outcome and check the vocabulary of the response.
    func testNoOutcomeEverAssertsAbsence() {
        let outcomes: [FakeLogSource] = [
            FakeLogSource(),
            FakeLogSource(lines: [Synthetic.line(offset: 0)]),
            FakeLogSource(end: .exhausted(exitStatus: 1, stderrTail: "x")),
            FakeLogSource(end: .deadline),
            FakeLogSource(end: .scanCap),
            FakeLogSource(end: .spawnFailed("x")),
            FakeLogSource(lines: [Data(#"{"foo":1}"#.utf8)]),
        ]
        let allowedStatus: Set<String> = ["ok", "no_events_in_window", "unavailable"]
        let bannedKeyFragments = ["uploaded", "synced", "happened", "occurred", "missing", "absent", "failed_to"]
        for source in outcomes {
            let r = run(source)
            XCTAssertTrue(allowedStatus.contains(r["status"] as? String ?? ""), "\(r["status"] ?? "nil")")
            for key in r.keys {
                for banned in bannedKeyFragments {
                    XCTAssertFalse(key.lowercased().contains(banned), "key \(key) asserts a negative outcome")
                }
            }
        }
    }
}
