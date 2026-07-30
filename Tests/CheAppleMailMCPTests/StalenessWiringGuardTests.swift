import XCTest
@testable import CheAppleMailMCP

/// #303 verify round 4 — wiring proven against the REAL reader and REAL stderr,
/// with no test seams in production code.
///
/// The lineage of this file is the lesson:
///   R2: text guards (`contains("stalenessWarningOnce")`) — defeated by
///       commenting the code out.
///   R3: better text guards — defeated outright by a decoy string, by nested
///       block comments, and by `{` in a string literal. Text is not behavior.
///   R4: behavioral tests via injected seams — defeated by
///       `guard stalenessReaderOverride != nil else { return }`, because a test
///       must ENABLE the seam to control the version it reads, so its
///       verification was coupled to the very condition the mutation keys on.
///       The test could only observe a world it had already intervened in.
///
/// So this version injects nothing. It builds a real sidecar next to a real
/// executable, runs it as a real process, and reads its real stderr. There is
/// no seam to key off, and the production sink is exercised rather than
/// substituted — which matters, since that sink could crash the server (R4).
final class StalenessWiringGuardTests: XCTestCase {

    /// Locate the built product directory (where `swift test`'s bundle lives),
    /// which is also where the server executable is built.
    private func builtProductsDir() throws -> URL {
        let bundle = Bundle(for: type(of: self))
        return bundle.bundleURL.deletingLastPathComponent()
    }

    /// The end-to-end proof: a real binary + a real drifted sidecar must print
    /// a real warning on real stderr.
    ///
    /// This cannot be satisfied by a decoy string, by commented-out code, or by
    /// a guard keyed on a test seam — there is no seam, and nothing but the
    /// production path can produce the output being asserted.
    func testRealBinary_withDriftedSidecar_warnsOnRealStderr() throws {
        let products = try builtProductsDir()
        let server = products.appendingPathComponent("CheAppleMailMCP")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: server.path),
                          "server executable not built in \(products.path)")

        // Stage a private copy so we never write a sidecar next to the real build.
        let lab = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("staleness-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: lab, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lab) }

        let exe = lab.appendingPathComponent("CheAppleMailMCP")
        try FileManager.default.copyItem(at: server, to: exe)
        try "99.0.0".write(to: lab.appendingPathComponent(".CheAppleMailMCP.version"),
                           atomically: true, encoding: .utf8)

        let stderr = try runBriefly(exe)

        XCTAssertTrue(stderr.contains("stale binary"),
            "a real drifted sidecar must produce the warning through the production path. "
            + "Empty means the wiring is gone from preflightAutomation(), the reader is "
            + "broken, or the sink is not writing.\nstderr was:\n\(stderr)")
        XCTAssertTrue(stderr.contains("99.0.0"), "must name the on-disk version")
        XCTAssertTrue(stderr.lowercased().contains("restart"), "must be actionable")
    }

    /// The negative half — without which the test above could pass on a server
    /// that warns unconditionally.
    func testRealBinary_withMatchingSidecar_staysSilent() throws {
        let products = try builtProductsDir()
        let server = products.appendingPathComponent("CheAppleMailMCP")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: server.path),
                          "server executable not built in \(products.path)")

        let lab = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("staleness-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: lab, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lab) }

        let exe = lab.appendingPathComponent("CheAppleMailMCP")
        try FileManager.default.copyItem(at: server, to: exe)
        try AppVersion.current.write(to: lab.appendingPathComponent(".CheAppleMailMCP.version"),
                                     atomically: true, encoding: .utf8)

        let stderr = try runBriefly(exe)
        XCTAssertFalse(stderr.contains("stale binary"),
                       "no drift → no warning. stderr was:\n\(stderr)")
    }

    /// Run the server just long enough for its startup path to reach the
    /// preflight, then terminate it and return whatever it wrote to stderr.
    /// stdin is held open briefly because the server exits as soon as stdin
    /// closes — which would race the fire-and-forget startup task.
    private func runBriefly(_ exe: URL, seconds: TimeInterval = 6) throws -> String {
        let p = Process()
        p.executableURL = exe
        let err = Pipe(), inp = Pipe(), out = Pipe()
        p.standardError = err; p.standardInput = inp; p.standardOutput = out

        // Drain concurrently: a full pipe buffer would block the child.
        let collected = NSMutableData()
        let lock = NSLock()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { lock.lock(); collected.append(d); lock.unlock() }
        }

        try p.run()
        Thread.sleep(forTimeInterval: seconds)
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        try? inp.fileHandleForWriting.close()
        _ = try? out.fileHandleForReading.readToEnd()

        lock.lock(); defer { lock.unlock() }
        return String(data: collected as Data, encoding: .utf8) ?? ""
    }

    // MARK: - the handshake version cannot silently re-rot
    //
    // This one legitimately stays a source assertion: it is a claim about what
    // the source SAYS (no hardcoded literal), not about what executes.

    func testServer_reportsAppVersionNotAHardcodedLiteral() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheAppleMailMCP/Server.swift"), encoding: .utf8)

        XCTAssertTrue(src.contains("version: AppVersion.current"),
            "the MCP handshake must report AppVersion.current — it was hardcoded \"2.7.2\" "
            + "for ~18 releases before #303")

        let hardcoded = try NSRegularExpression(pattern: #"version:\s*"\d+\.\d+\.\d+""#)
        let ns = src as NSString
        XCTAssertEqual(
            hardcoded.numberOfMatches(in: src, range: NSRange(location: 0, length: ns.length)), 0,
            "a hardcoded version literal reintroduces the rot AppVersion.current exists to prevent")
    }
}
