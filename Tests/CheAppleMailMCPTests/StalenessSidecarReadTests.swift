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

    /// The B1 proof. A reader-less FIFO is the one-command DoS
    /// (`mkfifo ~/bin/.CheAppleMailMCP.version`) that would otherwise wedge the
    /// actor forever. Returning nil is necessary but NOT sufficient evidence —
    /// only the time bound proves we did not block.
    func testFifo_failsFastDoesNotHang() throws {
        let p = path("fifo.version")
        guard mkfifo(p, 0o644) == 0 else {
            throw XCTSkip("mkfifo unavailable in this environment (errno \(errno))")
        }

        let started = Date()
        let result = MailController.readVersionSidecar(at: p)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(result, "a FIFO is not a regular file — must be rejected")
        XCTAssertLessThan(elapsed, 2.0,
            "must fail FAST: an unbounded open/read on a reader-less FIFO blocks forever "
            + "and would stall every AppleScript tool behind this actor (#303 verify B1)")
    }

    func testCharacterDevice_isRejected() {
        // /dev/zero opens fine and yields endless bytes — the fstat S_ISREG
        // check is what stops an unbounded read, not the byte cap alone.
        let started = Date()
        let result = MailController.readVersionSidecar(at: "/dev/zero")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(result, "a character device must be rejected (not S_ISREG)")
        XCTAssertLessThan(elapsed, 2.0, "and must not read endlessly")
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

        let started = Date()
        let result = MailController.readVersionSidecar(at: p)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 2.0, "the read must be byte-capped, not file-sized")
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
