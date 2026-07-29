import XCTest
@testable import CheAppleMailMCP

/// #303 verify B1/#5 — the LIVE layer: the actual filesystem read.
///
/// Its absence is why B1 survived review: the prior suite exercised only the
/// pure comparison and an injected `reader` closure, so the whole
/// `readVersionSidecar` → `preflightAutomation` path could have been deleted
/// with the suite still green.
///
/// This read runs OUTSIDE `#297`'s `runGuarded`, on the serial executor of the
/// process-wide singleton `actor MailController` — so a block here stalls every
/// AppleScript-backed tool. Defenses mirror `ExportDirLock` (#236); the FIFO
/// case in particular asserts PROMPTNESS, because a hang and a rejection both
/// eventually yield "no warning" and only the clock distinguishes them.
final class StalenessSidecarReadTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("staleness-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    // MARK: - happy path

    func testRegularFile_returnsTrimmedValue() throws {
        let p = path(".CheAppleMailMCP.version")
        try "2.26.0\n".write(toFile: p, atomically: true, encoding: .utf8)
        XCTAssertEqual(MailController.readVersionSidecar(at: p), "2.26.0")
    }

    func testMissingFile_failsOpen() {
        XCTAssertNil(MailController.readVersionSidecar(at: path("nope.version")))
    }

    func testBlankAndWhitespaceOnly_failOpen() throws {
        let blank = path("blank.version")
        try "".write(toFile: blank, atomically: true, encoding: .utf8)
        XCTAssertNil(MailController.readVersionSidecar(at: blank))

        let ws = path("ws.version")
        try "   \n\t \n".write(toFile: ws, atomically: true, encoding: .utf8)
        XCTAssertNil(MailController.readVersionSidecar(at: ws))
    }

    // MARK: - hostile / pathological inputs (the B1 defenses)

    func testSymlink_isRefusedNotFollowed() throws {
        let real = path("real.version")
        try "99.0.0".write(toFile: real, atomically: true, encoding: .utf8)
        let link = path("link.version")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        XCTAssertNil(MailController.readVersionSidecar(at: link),
                     "O_NOFOLLOW must refuse a planted symlink (ELOOP), not follow it")
    }

    /// Run `body` on a detached thread and fail (rather than hang) if it does
    /// not finish within `deadline`.
    ///
    /// Measuring `Date()` around a synchronous call is NOT a timeout: if the
    /// call blocks, control never reaches the assertion and the whole suite
    /// hangs until an external CI kill (#303 verify round 2, Codex). This makes
    /// the bound *executable* — a regression to a blocking `open()` produces a
    /// red test instead of a wedged run.
    ///
    /// Residual, stated: on timeout the worker thread is leaked, because the
    /// blocking syscall is uncancellable. That is the same tradeoff #297 took
    /// in production for `NSAppleScript`; the point is to bound the *test*, not
    /// to pretend the syscall was cancelled.
    private func withDeadline<T>(_ deadline: TimeInterval,
                                 _ body: @escaping () -> T,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) -> T? {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Thread.detachNewThread { box.value = body(); done.signal() }
        if done.wait(timeout: .now() + deadline) == .timedOut {
            XCTFail("blocked for more than \(deadline)s — the read is not bounded",
                    file: file, line: line)
            return nil
        }
        return box.value
    }

    private final class ResultBox<T>: @unchecked Sendable { var value: T? }

    /// The B1 proof. A reader-less FIFO is the one-command DoS
    /// (`mkfifo ~/bin/.CheAppleMailMCP.version`) that would otherwise wedge the
    /// actor — and with it every AppleScript-backed tool — forever.
    ///
    /// Two independent defenses cover this: `O_NONBLOCK` stops `open()` from
    /// waiting for a writer, and the subsequent `read` returns `EAGAIN`, caught
    /// by `guard n > 0`. (Mutation testing confirms the FIFO case survives even
    /// with the `fstat` check removed — `fstat`'s distinct job is the character
    /// device case below.)
    func testFifo_failsFastDoesNotHang() throws {
        let p = path("fifo.version")
        guard mkfifo(p, 0o644) == 0 else {
            throw XCTSkip("mkfifo unavailable in this environment (errno \(errno))")
        }

        let result = withDeadline(2.0) { MailController.readVersionSidecar(at: p) }
        XCTAssertEqual(result, .some(nil), "a reader-less FIFO must be rejected, promptly")
    }

    func testCharacterDevice_isRejected() {
        // /dev/zero opens fine and reads happily — the 64-byte cap alone would
        // already bound it, so what `fstat`/S_ISREG contributes here is
        // REJECTION (nil rather than 64 NUL bytes), not boundedness. Removing
        // the fstat check turns this test red; removing it does NOT affect the
        // FIFO case above. The two checks cover different threats.
        let result = withDeadline(2.0) { MailController.readVersionSidecar(at: "/dev/zero") }
        XCTAssertEqual(result, .some(nil), "a character device must be rejected (not S_ISREG)")
    }

    func testDirectory_isRejected() {
        XCTAssertNil(MailController.readVersionSidecar(at: dir.path),
                     "a directory is not a regular file")
    }

    func testOversizedFile_isBoundedAndDoesNotHang() throws {
        let p = path("huge.version")
        // 8 MiB of 'A' — a corrupt or malicious sidecar. The read must be
        // capped, not proportional to file size.
        try String(repeating: "A", count: 8 * 1024 * 1024)
            .write(toFile: p, atomically: true, encoding: .utf8)

        guard let result = withDeadline(2.0, { MailController.readVersionSidecar(at: p) }) else {
            return   // withDeadline already failed the test
        }
        // 'AAAA…' is not a semver, so evaluate() fails open regardless; what
        // matters is that only the capped prefix was ever read into memory.
        XCTAssertNil(StalenessCheck.evaluate(compiled: "2.25.0", sidecar: result),
                     "a garbage oversized sidecar must fail open")
        if let result { XCTAssertLessThanOrEqual(result.count, 64, "capped at the byte limit") }
    }

    // MARK: - end-to-end through the gate, on real files

    func testEndToEnd_realFileDrift_warnsThroughTheGate() throws {
        let p = path(".CheAppleMailMCP.version")
        try "99.0.0".write(toFile: p, atomically: true, encoding: .utf8)

        var state = false
        let warning = MailController.stalenessWarningOnce(
            state: &state, reader: { MailController.readVersionSidecar(at: p) })

        XCTAssertNotNil(warning, "a real on-disk newer version must warn")
        XCTAssertTrue(warning?.contains("99.0.0") == true)
        XCTAssertTrue(state, "gate consumed after an actual warning")
    }

    func testEndToEnd_matchingVersion_staysSilentAndArmed() throws {
        let p = path(".CheAppleMailMCP.version")
        try AppVersion.current.write(toFile: p, atomically: true, encoding: .utf8)

        var state = false
        XCTAssertNil(MailController.stalenessWarningOnce(
            state: &state, reader: { MailController.readVersionSidecar(at: p) }))
        XCTAssertFalse(state, "no drift → gate stays armed for a later update")

        // Now the update lands.
        try "99.0.0".write(toFile: p, atomically: true, encoding: .utf8)
        XCTAssertNotNil(MailController.stalenessWarningOnce(
            state: &state, reader: { MailController.readVersionSidecar(at: p) }),
            "the later on-disk update must still be detected")
    }
}
