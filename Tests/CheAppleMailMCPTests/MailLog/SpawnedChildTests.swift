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

    func testASecondReapDoesNothing() throws {
        let child = try spawn("exit 0")
        defer { finish(child) }
        XCTAssertEqual(child.reap(waitingUpTo: 3), 0)
        XCTAssertEqual(child.reap(waitingUpTo: 1), -1)
    }
}
