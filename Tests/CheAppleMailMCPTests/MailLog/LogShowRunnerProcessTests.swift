import Darwin
import XCTest
@testable import CheAppleMailMCP

/// #646 — what happens to the child and its descendants. The runner starts the child with
/// `posix_spawn` in its own process group, signals the group before reaping the leader, and reaps it
/// itself. Every test runs real `/bin/sh` children (no Mail, no `log`), and each one checks the
/// outcome that matters from outside: the leader is reaped (no zombie), nothing is left in its group,
/// the stderr reader finished, and no descriptor of ours stayed open. None depends on the content of
/// the real unified log.
final class LogShowRunnerProcessTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("idd646-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: helpers

    private func request() -> LogReadRequest {
        LogReadRequest(start: Date(timeIntervalSince1970: 1790916146),
                       end: Date(timeIntervalSince1970: 1790916206.2), categories: [])
    }

    private func runner(_ script: String, deadline: TimeInterval = 10, cap: Int = 64 * 1024 * 1024,
                        executable: String = "/bin/sh") -> LogShowRunner {
        LogShowRunner(executableURL: URL(fileURLWithPath: executable), deadline: deadline, scanCapBytes: cap,
                      makeArguments: { _ in ["-c", script] })
    }

    /// A unique, findable hold time for a long-lived descendant.
    private func hold() -> String { "20.\(Int.random(in: 100_000_000...999_999_999))" }

    private func path(_ name: String) -> String { scratch.appendingPathComponent(name).path }

    private func pid(in name: String) -> pid_t? {
        guard let text = try? String(contentsOfFile: path(name), encoding: .utf8),
              let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return value
    }

    private func exists(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }
    private func groupExists(_ pgid: pid_t) -> Bool { kill(-pgid, 0) == 0 }

    /// Polls up to `seconds`: a killed descendant is reaped by its new parent a moment later.
    private func eventually(_ seconds: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    private func openDescriptorCount() -> Int {
        (0..<4096).reduce(0) { fcntl(Int32($1), F_GETFD) >= 0 ? $0 + 1 : $0 }
    }

    /// Everything the runner promises after `read` returns, checked from outside.
    private func assertCleanedUp(leader leaderFile: String, descendants: [String] = [],
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let leader = pid(in: leaderFile) else {
            return XCTFail("the child never wrote its pid", file: file, line: line)
        }
        // Reaped by us, so it is gone at once: a zombie would still answer kill(pid, 0).
        XCTAssertFalse(exists(leader), "the leader was not reaped (zombie or running)", file: file, line: line)
        XCTAssertTrue(eventually { !self.groupExists(leader) },
                      "something is still in the child's process group", file: file, line: line)
        for name in descendants {
            guard let d = pid(in: name) else { XCTFail("no pid in \(name)", file: file, line: line); continue }
            XCTAssertTrue(eventually { !self.exists(d) }, "descendant \(name) survived the read", file: file, line: line)
        }
        let before = LogShowRunner.liveStderrReaders
        XCTAssertTrue(eventually { LogShowRunner.liveStderrReaders == 0 },
                      "a stderr reader is still blocked (\(before) live)", file: file, line: line)
    }

    private func read(_ r: LogShowRunner, cancel after: TimeInterval? = nil, stopAfter: Int = .max)
        -> ([String], LogReadEnd, Duration) {
        let cancellation = LogReadCancellation()
        if let after { DispatchQueue.global().asyncAfter(deadline: .now() + after) { cancellation.cancel() } }
        var lines: [String] = []
        var end: LogReadEnd = .spawnFailed("not run")
        let elapsed = ContinuousClock().measure {
            end = r.read(request(), cancellation: cancellation) { data in
                lines.append(String(decoding: data, as: UTF8.self))
                return lines.count < stopAfter
            }
        }
        return (lines, end, elapsed)
    }

    // MARK: normal exit

    func testNormalExit_reapsTheLeader_andReportsItsStatus() {
        let (lines, end, _) = read(runner("echo $$ > '\(path("p"))'; echo a; echo oops >&2; exit 4"))
        XCTAssertEqual(lines, ["a"])
        XCTAssertEqual(end, .exhausted(exitStatus: 4, stderrTail: "oops"))
        assertCleanedUp(leader: "p")
    }

    func testAChildKilledBySignal_reportsTheSignalNumber() {
        let (_, end, _) = read(runner("echo $$ > '\(path("p"))'; kill -9 $$"))
        XCTAssertEqual(end, .exhausted(exitStatus: 9, stderrTail: ""))
        assertCleanedUp(leader: "p")
    }

    func testNormalExit_sweepsADescendantThatHoldsNoPipe() {
        // Leaves the leader's group nothing to run in: it holds neither pipe, so only the group signal
        // can reach it.
        let h = hold()
        let (_, end, secs) = read(runner(
            "echo $$ > '\(path("p"))'; (exec sleep \(h) </dev/null >/dev/null 2>&1) & echo $! > '\(path("g"))'; echo a"))
        XCTAssertEqual(end, .exhausted(exitStatus: 0, stderrTail: ""))
        XCTAssertLessThan(secs, .seconds(4))
        assertCleanedUp(leader: "p", descendants: ["g"])
    }

    // MARK: natural EOF with a descendant on the pipe

    func testNaturalEOF_aDescendantHoldingOnlyStderr_isSignalledAndItsReaderFinishes() {
        let h = hold()
        // The shell exits at once; `sleep` keeps stderr (and only stderr) open.
        let (lines, end, secs) = read(runner(
            "echo $$ > '\(path("p"))'; echo a; (exec sleep \(h) >/dev/null) & echo $! > '\(path("g"))'"))
        XCTAssertEqual(lines, ["a"])
        XCTAssertEqual(end, .exhausted(exitStatus: 0, stderrTail: ""))
        XCTAssertLessThan(secs, .seconds(5), "the held stderr pipe must not outlast the 2 s wait (took \(secs))")
        assertCleanedUp(leader: "p", descendants: ["g"])
    }

    // MARK: forced stops

    func testHandlerStop_signalsTheGroup() {
        let h = hold()
        let (lines, end, secs) = read(runner(
            "echo $$ > '\(path("p"))'; sleep \(h) & echo $! > '\(path("g"))'; echo a; echo b; wait"), stopAfter: 2)
        XCTAssertEqual(lines, ["a", "b"])
        XCTAssertEqual(end, .stoppedByHandler)
        XCTAssertLessThan(secs, .seconds(5))
        assertCleanedUp(leader: "p", descendants: ["g"])
    }

    func testDeadline_signalsTheGroupWhenADescendantHoldsBothPipes() {
        let h = hold()
        let (_, end, secs) = read(runner(
            "echo $$ > '\(path("p"))'; sleep \(h) & echo $! > '\(path("g"))'; echo a; wait", deadline: 1))
        XCTAssertEqual(end, .deadline)
        XCTAssertLessThan(secs, .seconds(6))
        assertCleanedUp(leader: "p", descendants: ["g"])
    }

    func testScanCap_signalsTheGroup() {
        let h = hold()
        let (_, end, secs) = read(runner(
            "echo $$ > '\(path("p"))'; sleep \(h) & echo $! > '\(path("g"))'; exec yes '{\"x\":1}'", cap: 4096))
        XCTAssertEqual(end, .scanCap)
        XCTAssertLessThan(secs, .seconds(5))
        assertCleanedUp(leader: "p", descendants: ["g"])
    }

    func testCancel_signalsTheGroupOfASilentChild() {
        let h = hold()
        let (_, end, secs) = read(runner(
            "echo $$ > '\(path("p"))'; sleep \(h) & echo $! > '\(path("g"))'; wait", deadline: 25), cancel: 0.4)
        XCTAssertEqual(end, .cancelled)
        XCTAssertLessThan(secs, .seconds(5), "well before the 25 s deadline (took \(secs))")
        assertCleanedUp(leader: "p", descendants: ["g"])
    }

    func testAStop_triesSIGTERMBeforeSIGKILL() {
        // A leader that cleans up on TERM can only do so if TERM arrives, and before KILL.
        let (_, end, _) = read(runner(
            "trap 'echo termed > \'\(path("t"))\'; exit 0' TERM; echo $$ > '\(path("p"))'; echo a; while true; do sleep 1; done"),
            stopAfter: 1)
        XCTAssertEqual(end, .stoppedByHandler)
        XCTAssertEqual(try? String(contentsOfFile: path("t"), encoding: .utf8), "termed\n",
                       "the leader never saw SIGTERM")
        assertCleanedUp(leader: "p")
    }

    func testAGroupThatIgnoresSIGTERM_isStillKilled() {
        // The leader and the descendant both ignore TERM (an ignored signal survives exec), so only
        // the SIGKILL that follows the grace period can end them.
        let h = hold()
        let (lines, end, secs) = read(runner(
            "trap '' TERM; echo $$ > '\(path("p"))'; sleep \(h) & echo $! > '\(path("g"))'; echo a; while true; do sleep 1; done"),
            stopAfter: 1)
        XCTAssertEqual(lines, ["a"])
        XCTAssertEqual(end, .stoppedByHandler)
        XCTAssertGreaterThan(secs, .seconds(1.5), "TERM should have been tried for its grace period first")
        XCTAssertLessThan(secs, .seconds(6))
        assertCleanedUp(leader: "p", descendants: ["g"])
    }

    // MARK: spawn failure

    func testSpawnFailure_reportsAnErrorAndLeavesNothingOpen() {
        let readers = LogShowRunner.liveStderrReaders
        let before = openDescriptorCount()
        for missing in ["/nonexistent/definitely-not-here", "/etc/hosts"] {   // ENOENT, EACCES
            let (_, end, secs) = read(runner("", executable: missing))
            guard case .spawnFailed(let why) = end else { return XCTFail("expected spawnFailed, got \(end)") }
            XCTAssertTrue(why.contains(missing) && why.count > missing.count + 20, why)
            XCTAssertLessThan(secs, .seconds(2), "a failed spawn must not wait for anything")
        }
        XCTAssertEqual(LogShowRunner.liveStderrReaders, readers)
        XCTAssertEqual(openDescriptorCount(), before, "a failed spawn leaked a descriptor")
    }

    // MARK: output volume

    func testLargeStdoutAndStderrTogether_areDrainedWithoutDeadlock() {
        // Stderr alone is several pipe buffers and goes first: a child blocked on a full stderr pipe
        // would never reach the stdout lines.
        let (lines, end, secs) = read(runner(
            "head -c 300000 /dev/zero | tr '\\0' e >&2; yes abcdefghij | head -n 400000"), stopAfter: .max)
        XCTAssertEqual(lines.count, 400_000)
        guard case .exhausted(let status, let tail) = end else { return XCTFail("expected exhausted, got \(end)") }
        XCTAssertEqual(status, 0)
        XCTAssertEqual(tail.utf8.count, 2048)
        XCTAssertLessThan(secs, .seconds(8))
    }

    // MARK: descriptors

    func testEveryPath_closesEveryDescriptor() {
        let h = hold()
        let paths: [(String, () -> Void)] = [
            ("normal", { _ = self.read(self.runner("echo a")) }),
            ("handler stop", { _ = self.read(self.runner("exec yes x"), stopAfter: 2) }),
            ("deadline", { _ = self.read(self.runner("sleep \(h) & wait", deadline: 0.5)) }),
            ("cancel", { _ = self.read(self.runner("sleep \(h) & wait", deadline: 20), cancel: 0.2) }),
            ("scan cap", { _ = self.read(self.runner("exec yes '{}'", cap: 2048)) }),
            ("spawn failure", { _ = self.read(self.runner("", executable: "/nonexistent/x")) }),
        ]
        // Warm up once so lazily opened descriptors (Dispatch, Foundation) are part of the baseline.
        for (_, run) in paths { run() }
        XCTAssertTrue(eventually { LogShowRunner.liveStderrReaders == 0 })
        let before = openDescriptorCount()
        for (name, run) in paths {
            for _ in 0..<3 { run() }
            XCTAssertTrue(eventually { LogShowRunner.liveStderrReaders == 0 }, "\(name): a stderr reader never finished")
            XCTAssertEqual(openDescriptorCount(), before, "\(name): leaked a descriptor")
        }
        Process.pkill("sleep \(h)")
    }

    func testTheChildInheritsNoOtherDescriptor() {
        // An inheritable descriptor of ours, deliberately not close-on-exec.
        let leaked = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThan(leaked, 2)
        defer { close(leaked) }
        XCTAssertEqual(fcntl(leaked, F_SETFD, 0), 0)
        let (lines, end, _) = read(runner("if [ -e /dev/fd/\(leaked) ]; then echo leaked; else echo clean; fi"))
        XCTAssertEqual(lines, ["clean"])
        XCTAssertEqual(end, .exhausted(exitStatus: 0, stderrTail: ""))
    }

    // MARK: identity of the child

    func testTheChildLeadsAGroupOfItsOwn() {
        let (lines, _, _) = read(runner("echo $$; ps -o pgid= -p $$"))
        XCTAssertEqual(lines.count, 2)
        let ids = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(ids[0], ids[1], "the child must be its own group leader")
        XCTAssertNotEqual(ids[1], String(getpgrp()), "the child must not share the server's group")
    }

    func testTheChildGetsTheFixedEnvironmentAndDefaultSignals() {
        // The test process ignores SIGPIPE here; the child must not inherit that.
        signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, SIG_DFL) }
        // `yes` writing into a pipe whose reader (`head`) has left dies of SIGPIPE (status 141) only when
        // SIGPIPE is default; with it ignored it fails with EPIPE and exits 1. fd 3 is our stdout.
        let (lines, _, _) = read(runner("echo $LANG; exec 3>&1; { yes; echo $? >&3; } | head -n 1 >/dev/null"))
        XCTAssertEqual(lines, ["en_US.UTF-8", "141"], "SIGPIPE must be default in the child")
    }
}

private extension Process {
    /// Safety net only: the tests assert that nothing needs it.
    static func pkill(_ pattern: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", pattern]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
}
