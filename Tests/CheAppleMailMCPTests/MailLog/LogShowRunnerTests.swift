import XCTest
@testable import CheAppleMailMCP

/// #465 — the bounded-subprocess contract (task 1.2). Fake children are
/// `/bin/sh -c` one-liners, so the REAL spawn/read/terminate/reap path runs.
final class LogShowRunnerTests: XCTestCase {

    private func request() -> LogReadRequest {
        LogReadRequest(start: Date(timeIntervalSince1970: 1790916146),
                       end: Date(timeIntervalSince1970: 1790916206.2),
                       categories: [])
    }

    private func shRunner(_ script: String, deadline: TimeInterval = 10, cap: Int = 64 * 1024 * 1024) -> LogShowRunner {
        LogShowRunner(executableURL: URL(fileURLWithPath: "/bin/sh"), deadline: deadline, scanCapBytes: cap,
                      makeArguments: { _ in ["-c", script] })
    }

    private func collect(_ runner: LogShowRunner, stopAfter: Int = .max) -> ([String], LogReadEnd, TimeInterval) {
        var lines: [String] = []
        let t0 = Date()
        let end = runner.read(request()) { data in
            lines.append(String(decoding: data, as: UTF8.self))
            return lines.count < stopAfter
        }
        return (lines, end, Date().timeIntervalSince(t0))
    }

    // MARK: argument construction

    func testArguments_areFixedTextPlusValidatedTokens_inLocalTime() {
        let taipei = TimeZone(secondsFromGMT: 8 * 3600)!
        let req = LogReadRequest(start: Date(timeIntervalSince1970: 1790916146),
                                 end: Date(timeIntervalSince1970: 1790916206.2),
                                 categories: [LogCategoryToken("IMAPSyncActivity")!, LogCategoryToken("Drafts")!])
        // start floors to the second, end CEILS (so an event in the final
        // fraction of the last second is not lost). Literals computed by hand.
        XCTAssertEqual(LogShowRunner.arguments(for: req, timeZone: taipei), [
            "show", "--style", "ndjson",
            "--start", "2026-10-02 12:42:26",
            "--end", "2026-10-02 12:43:27",
            "--predicate",
            #"(subsystem BEGINSWITH "com.apple.mail" OR subsystem BEGINSWITH "com.apple.email") AND (category == "IMAPSyncActivity" OR category == "Drafts")"#,
        ])
    }

    func testArguments_noCategories_omitsTheCategoryClause() {
        let args = LogShowRunner.arguments(for: request(), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(args.last, #"(subsystem BEGINSWITH "com.apple.mail" OR subsystem BEGINSWITH "com.apple.email")"#)
    }

    func testCategoryToken_rejectsAnythingThatCouldEscapeAPredicate() {
        for bad in ["", "a b", "a\"b", "a)b", "a' OR 1==1", "a\\b", String(repeating: "x", count: 65), "カテゴリ", "Drafts\n", "Drafts\r\n", "\nDrafts", "Dra\u{0}fts"] {
            XCTAssertNil(LogCategoryToken(bad), "must reject \(bad.debugDescription)")
        }
        for good in ["IMAPSyncActivity", "EDLocalActionPersistence", "a.b-c_d", "X"] {
            XCTAssertNotNil(LogCategoryToken(good))
        }
    }

    // MARK: stream, status, stderr

    func testReadsLinesAndReportsExitStatusAndStderr() {
        let (lines, end, _) = collect(shRunner("echo a; echo b; echo oops >&2; exit 3"))
        XCTAssertEqual(lines, ["a", "b"])
        XCTAssertEqual(end, .exhausted(exitStatus: 3, stderrTail: "oops"))
    }

    func testFinalLineWithoutNewlineIsStillDelivered() {
        let (lines, end, _) = collect(shRunner("printf 'a\\nb'"))
        XCTAssertEqual(lines, ["a", "b"])
        XCTAssertEqual(end, .exhausted(exitStatus: 0, stderrTail: ""))
    }

    func testStderrTailIsBounded() {
        let (_, end, _) = collect(shRunner("head -c 200000 /dev/zero | tr '\\0' x >&2; exit 1"))
        guard case .exhausted(let status, let tail) = end else { return XCTFail("expected exhausted, got \(end)") }
        XCTAssertEqual(status, 1)
        XCTAssertLessThanOrEqual(tail.utf8.count, 2048)
        XCTAssertFalse(tail.isEmpty)
    }

    func testChildDoesNotInheritStdin() {
        // `cat` with an inherited terminal/pipe stdin would block until the deadline.
        let (_, end, secs) = collect(shRunner("cat", deadline: 8))
        XCTAssertEqual(end, .exhausted(exitStatus: 0, stderrTail: ""))
        XCTAssertLessThan(secs, 5)
    }

    // MARK: bounds

    func testSpawnFailure() {
        let runner = LogShowRunner(executableURL: URL(fileURLWithPath: "/nonexistent/definitely-not-here"),
                                   makeArguments: { _ in [] })
        let (_, end, _) = collect(runner)
        guard case .spawnFailed(let why) = end else { return XCTFail("expected spawnFailed, got \(end)") }
        XCTAssertFalse(why.isEmpty)
    }

    func testHandlerStop_terminatesAndReapsAnEndlessChild_within5Seconds() {
        let marker = "idd465-endless-\(UUID().uuidString)"
        let (lines, end, secs) = collect(shRunner("# \(marker)\nwhile true; do echo '{\"x\":1}'; done"), stopAfter: 3)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(end, .stoppedByHandler)
        XCTAssertLessThan(secs, 5)
        // The child must actually be gone, not merely abandoned.
        let deadline = Date().addingTimeInterval(3)
        var alive = true
        while Date() < deadline {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-f", marker]
            p.standardOutput = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 { alive = false; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertFalse(alive, "endless child still running after the read returned")
    }

    func testScanCap_stopsAnEndlessChild() {
        let (lines, end, secs) = collect(shRunner("while true; do echo '{\"x\":1}'; done", cap: 4096))
        XCTAssertEqual(end, .scanCap)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertLessThan(secs, 5)
    }

    func testDeadline_returnsWhatWasReadThenReportsDeadline() {
        let (lines, end, secs) = collect(shRunner("echo a; exec sleep 30", deadline: 1))
        XCTAssertEqual(lines, ["a"])
        XCTAssertEqual(end, .deadline)
        XCTAssertLessThan(secs, 6, "a stalled child must be killed at the deadline, not waited on")
    }

    func testDeadline_isEnforcedEvenWhenAGrandchildHoldsThePipeOpen() {
        // Not `exec`: the shell forks `sleep`, which inherits stdout. Killing the
        // shell does NOT produce EOF, so a read-until-EOF design would sit here
        // for the full 3 seconds (#301 hit this with osascript).
        let (_, end, secs) = collect(shRunner("echo a; sleep 3", deadline: 1))
        XCTAssertEqual(end, .deadline)
        XCTAssertLessThan(secs, 2.5, "deadline must not depend on the pipe reaching EOF")
    }

    /// Verify round 3, findings 3/5/11: `log show --start T --end T` returns nothing (measured), and
    /// `--end` at a whole second leaves out that second. The window end always rounds UP to the NEXT
    /// whole second; the service trims to the exact window.
    func testArguments_endIsAlwaysPastTheWindowsLastSecond() {
        let taipei = TimeZone(secondsFromGMT: 8 * 3600)!
        let t = Date(timeIntervalSince1970: 1790916146)                 // 12:42:26.000
        let zeroWidth = LogShowRunner.arguments(for: LogReadRequest(start: t, end: t, categories: []), timeZone: taipei)
        XCTAssertEqual(zeroWidth[4], "2026-10-02 12:42:26")
        XCTAssertEqual(zeroWidth[6], "2026-10-02 12:42:27")
        let wholeEnd = LogShowRunner.arguments(for: LogReadRequest(start: t, end: t.addingTimeInterval(60), categories: []), timeZone: taipei)
        XCTAssertEqual(wholeEnd[6], "2026-10-02 12:43:27")
    }
}
