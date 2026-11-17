import Darwin
import XCTest
@testable import CheAppleMailMCP

/// #646 — the spawn wrapper on its own: the order the runner depends on (observe, signal, reap).
final class SpawnedChildTests: XCTestCase {

    private func spawn(_ script: String) throws -> SpawnedChild {
        try SpawnedChild.spawn(executablePath: "/bin/sh", arguments: ["-c", script], environment: [:])
    }

    private func finish(_ child: SpawnedChild) { close(child.stdoutFD); close(child.stderrFD) }

    func testAnExitedLeaderStaysAZombieUntilItIsReaped() throws {
        let child = try spawn("exit 7")
        defer { finish(child) }
        XCTAssertTrue(child.waitForExit(timeout: 3))
        // Observed, not reaped: the number is still ours, which is what makes a group signal safe.
        XCTAssertEqual(kill(child.pid, 0), 0, "waitForExit must not reap")
        XCTAssertEqual(child.reap(waitingUpTo: 1), 7)
        XCTAssertEqual(kill(child.pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testTheChildIsItsOwnGroupLeader() throws {
        let child = try spawn("exec sleep 30")
        defer { finish(child) }
        XCTAssertEqual(getpgid(child.pid), child.pid)
        XCTAssertNotEqual(getpgid(child.pid), getpgrp())
        child.signalGroup(SIGKILL)
        XCTAssertEqual(child.reap(waitingUpTo: 3), SIGKILL)
    }

    func testAChildThatDoesNotExitIsHandedToABackgroundReaper() throws {
        let child = try spawn("exec sleep 30")
        defer { finish(child) }
        XCTAssertEqual(child.reap(waitingUpTo: 0.2), -1)
        // Released: a later group signal is refused, because the number is no longer ours to use.
        child.signalGroup(SIGKILL)
        XCTAssertEqual(kill(child.pid, 0), 0, "a released child must not be signalled as a group")
        kill(child.pid, SIGKILL)   // directly, by the test, as a stand-in for the child ending by itself
        let until = Date().addingTimeInterval(3)
        while kill(child.pid, 0) == 0, Date() < until { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(kill(child.pid, 0), -1, "the background reaper must collect it")
    }

    func testSignalGroupAfterTheReapReachesNothing() throws {
        // The leader leaves at once, a descendant stays in the group. Once the leader is reaped the
        // group number is no longer ours, so a group signal must not be sent, even to a live member.
        let child = try spawn("sleep 30 </dev/null >/dev/null 2>&1 & echo $!")
        defer { finish(child) }
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = read(child.stdoutFD, &buffer, buffer.count)
        let text = String(decoding: buffer[0..<max(n, 0)], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let descendant = try XCTUnwrap(pid_t(text))
        defer { kill(descendant, SIGKILL) }
        XCTAssertTrue(child.waitForExit(timeout: 3))
        XCTAssertEqual(child.reap(waitingUpTo: 1), 0)
        child.signalGroup(SIGKILL)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(kill(descendant, 0), 0, "a group signal went out after the leader was reaped")
    }

    func testASecondReapDoesNothing() throws {
        let child = try spawn("exit 0")
        defer { finish(child) }
        XCTAssertEqual(child.reap(waitingUpTo: 3), 0)
        XCTAssertEqual(child.reap(waitingUpTo: 1), -1)
    }
}
