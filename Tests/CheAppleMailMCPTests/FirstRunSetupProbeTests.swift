import XCTest
@testable import CheAppleMailMCP

/// #355 — the setup window existed since #213/#214 and nothing on the install
/// path ever opened it. The wrapper only compares versions, the session-start
/// hook only kills stale processes, and the README mentioned `--setup` only in
/// a reference section you had to already know to look for. So the one
/// convenient way to grant Full Disk Access was reachable only by people who
/// already knew it was there.
///
/// The blocker for automating it: asking "is FDA missing?" used to have a side
/// effect. `--check-fda` prints prose and, on `.denied`, OPENS System Settings —
/// so a session-start hook could not use it to detect anything without throwing
/// a settings window at the user on every single session. And it always exited
/// 0, so the answer was not machine-readable either.
///
/// `--check-fda --quiet` is the probe: status only, no output, no pane.
final class FirstRunSetupProbeTests: XCTestCase {

    func testQuietFlagSelectsTheSilentProbe() {
        XCTAssertEqual(RunMode.parse(["bin", "--check-fda", "--quiet"]), .checkFDAQuiet)
        XCTAssertEqual(RunMode.parse(["bin", "--quiet", "--check-fda"]), .checkFDAQuiet)
    }

    func testCheckFdaWithoutQuietKeepsTheOldLoudBehaviour() {
        XCTAssertEqual(RunMode.parse(["bin", "--check-fda"]), .checkFDA)
    }

    func testQuietAloneDoesNotDivertTheServer() {
        // `--quiet` is a MODIFIER, not a mode. A stray one must never stop the
        // stdio server from starting — that path must stay untouched (#213).
        XCTAssertEqual(RunMode.parse(["bin", "--quiet"]), .server)
        XCTAssertEqual(RunMode.parse(["bin"]), .server)
    }

    func testSetupStillWinsOverEverything() {
        XCTAssertEqual(RunMode.parse(["bin", "--setup", "--check-fda", "--quiet"]), .setup)
    }

    /// The statuses the hook branches on. Only `.granted` may be 0 — the hook
    /// treats "non-zero" as "worth offering the setup window".
    func testExitStatusMapping() {
        XCTAssertEqual(SetupCLI.status(for: .granted).rawValue, 0)
        XCTAssertEqual(SetupCLI.status(for: .denied).rawValue, 1)
        XCTAssertEqual(SetupCLI.status(for: .noMailData).rawValue, 2)
        XCTAssertEqual(SetupCLI.status(for: .undetermined).rawValue, 3)
    }

    /// The probe must be usable from a hook: no output on any path.
    func testQuietProbeReturnsAStatusWithoutPrinting() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let server = products.appendingPathComponent("CheAppleMailMCP")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: server.path),
                          "server executable not built next to the test bundle")

        let p = Process()
        p.executableURL = server
        p.arguments = ["--check-fda", "--quiet"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        XCTAssertTrue(o.isEmpty, "the quiet probe must print nothing on stdout")
        XCTAssertTrue(e.isEmpty, "the quiet probe must print nothing on stderr")
        XCTAssertTrue((0...3).contains(p.terminationStatus),
                      "unexpected status \(p.terminationStatus)")
    }
}
