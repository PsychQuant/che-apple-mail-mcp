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

    /// #468: timed with a monotonic clock. Every ceiling below is a multiple of the bound it guards,
    /// far from the time the broken design would take, so machine load cannot push the healthy path
    /// over it while a real regression still lands well past it.
    private func collect(_ runner: LogShowRunner, stopAfter: Int = .max) -> ([String], LogReadEnd, Duration) {
        var lines: [String] = []
        var end: LogReadEnd = .spawnFailed("not run")
        let elapsed = ContinuousClock().measure {
            end = runner.read(request()) { data in
                lines.append(String(decoding: data, as: UTF8.self))
                return lines.count < stopAfter
            }
        }
        return (lines, end, elapsed)
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
        XCTAssertLessThan(secs, .seconds(5), "cat took \(secs) against an 8 s deadline")
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
        // `yes` is endless but blocks on a full pipe instead of spinning a core the way a shell
        // `while true; do echo ...; done` loop did (#468). `exec` keeps the marker in its argv.
        let (lines, end, secs) = collect(shRunner("exec yes \(marker)"), stopAfter: 3)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(end, .stoppedByHandler)
        XCTAssertLessThan(secs, .seconds(5), "handler stop took \(secs)")
        // The child must actually be gone, not merely abandoned.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var alive = true
        while clock.now < deadline {
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
        let (lines, end, secs) = collect(shRunner("exec yes '{\"x\":1}'", cap: 4096))
        XCTAssertEqual(end, .scanCap)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertLessThan(secs, .seconds(5), "the scan cap took \(secs) to stop the child")
    }

    func testDeadline_returnsWhatWasReadThenReportsDeadline() {
        let (lines, end, secs) = collect(shRunner("echo a; exec sleep 30", deadline: 1))
        XCTAssertEqual(lines, ["a"])
        XCTAssertEqual(end, .deadline)
        XCTAssertLessThan(secs, .seconds(6), "a stalled child must be killed at the deadline, not waited on (took \(secs))")
    }

    func testDeadline_isEnforcedEvenWhenAGrandchildHoldsThePipeOpen() {
        // Not `exec`: the shell forks `sleep`, which inherits stdout. Killing the
        // shell does NOT produce EOF, so a read-until-EOF design would sit here
        // until the grandchild exits (#301 hit this with osascript).
        // #468: the grandchild holds the pipe 20 s, so the broken design takes 20 s while the
        // healthy one takes about 1.3 s (1 s deadline, a 250 ms poll slice, the terminate grace);
        // a 10 s ceiling sits far from both. The old 3 s hold against a 2.5 s ceiling left 1.2 s
        // of headroom under load. The fractional part makes the orphaned `sleep` findable.
        let hold = "20.\(Int.random(in: 100_000_000...999_999_999))"
        defer { Self.run("/usr/bin/pkill", ["-f", "sleep \(hold)"]) }
        let (_, end, secs) = collect(shRunner("echo a; sleep \(hold)", deadline: 1))
        XCTAssertEqual(end, .deadline)
        XCTAssertLessThan(secs, .seconds(10), "deadline must not depend on the pipe reaching EOF (took \(secs))")
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
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
