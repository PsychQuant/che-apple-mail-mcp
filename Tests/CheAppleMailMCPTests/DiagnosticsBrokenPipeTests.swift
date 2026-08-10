import XCTest
@testable import CheAppleMailMCP

/// #346 — `signal(SIGPIPE, SIG_IGN)` (#320) removed the signal-13 death but
/// converted none of the 26 non-throwing stderr writers. `SIG_IGN` hands the
/// write an `EPIPE` errno, and the **non-throwing** `FileHandle.write(_:)`
/// turns that into an uncatchable Objective-C exception — `SIGABRT`, exit 134
/// (verified by #303 on the real binary). Death by a different number is not
/// survival.
///
/// The existing `SigpipeDispositionTests` cannot see this, and says so in its
/// own doc comment: it *delivers* `SIGPIPE` to the process, which is exactly
/// what `SIG_IGN` handles, so it passes with or without the bug. That is the
/// failure mode #303's round 4 named — asserting on the mechanism you were
/// thinking about rather than the one that has to hold.
///
/// So this test performs a **real broken-pipe write**: fd 2 is redirected onto
/// a pipe whose read end is closed, and then **real diagnostic call sites** are
/// invoked. Going through actual call sites rather than the helper alone is
/// deliberate — testing only the helper would repeat this issue's own mistake
/// of verifying something you *believe* is on the path.
final class DiagnosticsBrokenPipeTests: XCTestCase {

    /// Run `body` with fd 2 pointed at a pipe whose read end is already closed,
    /// so every write to stderr fails with `EPIPE`. fd 2 and the `SIGPIPE`
    /// disposition are both restored afterwards whatever happens — the test
    /// runner needs them back.
    ///
    /// **The `SIG_IGN` line is not boilerplate.** The server installs it in
    /// `main.swift`; the *test host* does not, so the first version of this
    /// fixture killed the xctest process outright — `exited with unexpected
    /// signal code 13`. That is the pre-#320 behavior, reproduced live and by
    /// accident, and it makes the point concrete: without the disposition the
    /// write never returns to Swift at all, so there is no error for any API
    /// (throwing or not) to report. To test what the *server* does under a
    /// broken pipe, the fixture has to stand up the server's process state.
    private func withBrokenStderr(_ body: () -> Void) throws {
        let savedStderr = dup(STDERR_FILENO)
        try XCTSkipIf(savedStderr < 0, "could not duplicate fd 2")
        let savedSigpipe = signal(SIGPIPE, SIG_IGN)

        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0, "could not create the fixture pipe")
        close(fds[0])                       // reader gone → the pipe is broken

        defer {
            // A failed restore leaves fd 2 pointing at the broken pipe, which
            // would kill the test host on the next unrelated stderr write — so
            // retry EINTR and fail loudly rather than continue quietly.
            var rc = dup2(savedStderr, STDERR_FILENO)
            while rc < 0 && errno == EINTR { rc = dup2(savedStderr, STDERR_FILENO) }
            XCTAssertGreaterThanOrEqual(rc, 0, "could not restore fd 2 — later tests are unsafe")
            close(savedStderr)
            close(fds[1])
            signal(SIGPIPE, savedSigpipe)
        }
        XCTAssertEqual(dup2(fds[1], STDERR_FILENO), STDERR_FILENO,
                       "could not redirect fd 2 onto the broken pipe")
        body()
    }

    /// The helper itself: must report the failure, and must come back.
    func testEmit_onBrokenPipe_returnsFalseAndDoesNotCrash() throws {
        var delivered = true
        try withBrokenStderr {
            delivered = Diagnostics.emit("this line cannot be delivered\n")
        }
        XCTAssertFalse(delivered,
            "a write into a broken pipe did not fail — the fixture is not actually broken, "
            + "which would make every other assertion here vacuous")
    }

    /// A real call site — `decodeAccountId` writes a WARN when `account_id` is
    /// not a string. Reaching stderr through a genuine path is the point: under
    /// the non-throwing API this line aborted the process.
    func testRealCallSite_decodeAccountId_survivesBrokenPipe() throws {
        var result: String? = "unset"
        try withBrokenStderr {
            result = decodeAccountId(["account_id": .int(42)], tool: "save_attachment")
        }
        XCTAssertNil(result, "a non-string account_id still falls back to the name path")
    }

    /// Second real call site, on the read path a caller actually hits: the
    /// SQLite fast-path fall-through note (#100) — the example the issue gives.
    func testRealCallSite_fastPathFallthrough_survivesBrokenPipe() throws {
        try withBrokenStderr {
            logFastPathFallthrough(tool: "get_email", rowId: 1, reason: .rowIdNotIndexed)
        }
        // Reaching here at all is the assertion: the pre-#346 write raised an
        // uncatchable ObjC exception on EPIPE and the process never returned.
    }

    /// Delivery still works when stderr is healthy — a helper that always
    /// returned false would pass every test above while silently swallowing
    /// every diagnostic the server emits.
    func testEmit_onAHealthyDescriptor_actuallyWritesTheBytes() throws {
        let savedStderr = dup(STDERR_FILENO)
        try XCTSkipIf(savedStderr < 0, "could not duplicate fd 2")
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        defer { dup2(savedStderr, STDERR_FILENO); close(savedStderr); close(fds[0]); if fds[1] >= 0 { close(fds[1]) } }

        XCTAssertEqual(dup2(fds[1], STDERR_FILENO), STDERR_FILENO)
        let delivered = Diagnostics.emit("hello stderr\n")
        dup2(savedStderr, STDERR_FILENO)     // restore before reading, so a
                                             // failed read cannot cascade
        XCTAssertTrue(delivered)

        // Close EVERY writer end before reading. Verify round 1: with a writer
        // still open, a regression where `emit` silently wrote nothing would
        // leave `read` blocked forever — the suite would time out instead of
        // failing cleanly, and a hang is a much worse signal than a red test.
        close(fds[1]); fds[1] = -1
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(fds[0], &buf, 64)
        XCTAssertEqual(String(decoding: buf.prefix(max(0, n)), as: UTF8.self), "hello stderr\n",
                       "the bytes must land verbatim — the helper must not add or eat a newline, "
                       + "or all 26 converted messages (which carry their own) would drift")
    }

    /// `MailController.emitDiagnostic` is #303's contract: appends the newline,
    /// reports delivery. The staleness gate consumes its Bool, so a regression
    /// here would silently re-arm or swallow that one-shot warning.
    func testEmitDiagnostic_keepsItsAppendNewlineContract() throws {
        let savedStderr = dup(STDERR_FILENO)
        try XCTSkipIf(savedStderr < 0, "could not duplicate fd 2")
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        defer { dup2(savedStderr, STDERR_FILENO); close(savedStderr); close(fds[0]); if fds[1] >= 0 { close(fds[1]) } }

        XCTAssertEqual(dup2(fds[1], STDERR_FILENO), STDERR_FILENO)
        let delivered = MailController.emitDiagnostic("stale binary")
        dup2(savedStderr, STDERR_FILENO)
        XCTAssertTrue(delivered)

        close(fds[1]); fds[1] = -1        // see the note above: never read with a live writer
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(fds[0], &buf, 64)
        XCTAssertEqual(String(decoding: buf.prefix(max(0, n)), as: UTF8.self), "stale binary\n")
    }

    func testEmitDiagnostic_onBrokenPipe_reportsUndelivered() throws {
        var delivered = true
        try withBrokenStderr {
            delivered = MailController.emitDiagnostic("stale binary")
        }
        XCTAssertFalse(delivered,
            "#303's one-shot staleness gate stays armed only if a failed write reports false")
    }
}
