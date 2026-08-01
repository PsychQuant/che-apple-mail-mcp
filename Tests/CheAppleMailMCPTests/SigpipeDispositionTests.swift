import XCTest
@testable import CheAppleMailMCP

/// #320 — the server must survive `SIGPIPE`.
///
/// The kernel's default disposition kills a process that writes to a broken
/// pipe BEFORE `write()` returns to Swift, so no `try?`/`do-catch` can
/// intercept it. This server has ~26 stderr write sites plus a stdout stdio
/// transport; any of them could become the fatal write once a host closed its
/// read end (verified on the real binary during the #303 round-5 verify:
/// broken-pipe stderr + a startup diagnostic → killed by signal 13).
///
/// This test pins the DISPOSITION — the one thing #320 changes — by
/// delivering `SIGPIPE` to the real spawned binary directly: deterministic,
/// load-independent, and byte-equivalent to what the kernel raises on a
/// broken-pipe write. Before the fix the server dies by signal 13 (verified
/// 2/2 on the pre-fix binary); with `signal(SIGPIPE, SIG_IGN)` installed at
/// startup it survives (2/2), and broken-pipe writes surface as `EPIPE`
/// errnos that the throwing write sites already swallow.
///
/// Deliberately NOT tested here: "exits within N seconds of stdin EOF".
/// Interleaved A/B measurement showed shutdown-after-EOF latency is highly
/// variable on the UNMODIFIED binary too (4s to >40s under load — a
/// pre-existing property, likely the fire-and-forget startup sync's 45s
/// guard), so a bounded-exit assertion would flake on noise this change does
/// not own. The no-spin property was verified live (broken-pipe stdout +
/// stdin EOF → clean rc=0 exit) and is recorded in the PR.
final class SigpipeDispositionTests: XCTestCase {

    /// Skip-not-fail when the server product is absent mirrors the existing
    /// spawn-based tests' tradeoff; the skip is visible in the run summary.
    func testServerSurvivesDeliveredSIGPIPE() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let server = products.appendingPathComponent("CheAppleMailMCP")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: server.path),
                          "server executable not built next to the test bundle")

        let p = Process()
        p.executableURL = server
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = Pipe()   // hold both ends open — this test isolates
        p.standardError = Pipe()    // the signal itself from any pipe state
        try p.run()
        defer { if p.isRunning { p.terminate() }; p.waitUntilExit() }

        Thread.sleep(forTimeInterval: 1.5)   // past launch
        XCTAssertTrue(p.isRunning, "server must have started")

        kill(p.processIdentifier, SIGPIPE)
        Thread.sleep(forTimeInterval: 1.5)

        XCTAssertTrue(p.isRunning,
            "SIGPIPE killed the server — the default disposition is back. Before #320 "
            + "any write to a broken pipe (stderr diagnostics, stdout transport) was "
            + "fatal by signal 13; signal(SIGPIPE, SIG_IGN) at startup must hold.")
        try? stdin.fileHandleForWriting.close()
    }
}
