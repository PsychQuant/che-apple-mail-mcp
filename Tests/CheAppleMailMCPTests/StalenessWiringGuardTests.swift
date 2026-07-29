import XCTest
@testable import CheAppleMailMCP

/// #303 verify round 3 — BEHAVIORAL wiring tests, replacing the text-based
/// source guards that used to live here.
///
/// Those guards asserted that the string `"stalenessWarningOnce"` appeared
/// inside `preflightAutomation`'s source. Round 3 showed that cannot work:
///
///   - a decoy (`_ = "stalenessWarningOnce didWarnStaleness"`) passed every
///     assertion with the real call deleted and the check disabled;
///   - Swift permits NESTED block comments, which the hand-rolled stripper
///     (a boolean, not a depth counter) closed early;
///   - a `"{"` inside a string literal inflated the brace count so
///     `functionBody` overran into the following declarations — which happen
///     to contain both identifiers, yielding a false pass.
///
/// Each of those was patched and then bypassed again by the next legal-Swift
/// construct, because the premise was wrong: **text is not behavior**. Only
/// calling the real function and observing its effect proves the wiring runs.
/// This follows the file's own established `setTestSeams` convention
/// (`scriptRunnerOverride` etc.), which existed all along.
final class StalenessWiringGuardTests: XCTestCase {

    private func makeController() -> MailController { MailController.shared }

    override func tearDown() async throws {
        await MailController.shared.setTestSeams(
            scriptRunner: nil, ineligibility: nil, openURL: nil,
            scriptTimeout: nil, stalenessReader: nil, stalenessSink: nil)
        await MailController.shared.resetStalenessGateForTesting()
    }

    /// THE wiring test. It must enter through a real caller, not through
    /// `runStalenessCheck()` directly — an earlier version of this test called
    /// the extracted method and therefore proved nothing about whether
    /// `preflightAutomation()` invokes it (deleting the call left the test
    /// green, exactly like the text guards it replaced).
    ///
    /// `runScriptAsList` is the entry point that reaches `preflightAutomation()`
    /// unconditionally — unlike `runScript`, it has no `scriptRunnerOverride`
    /// short-circuit. The call is expected to throw afterwards (no live Mail /
    /// no Automation grant in CI); that is irrelevant, because the staleness
    /// check runs BEFORE `AutomationStatus.probe()`. What matters is that the
    /// warning reached the sink on the way through.
    func testDriftReachesTheSink_throughTheRealChokepoint() async {
        let sink = Sink()
        await MailController.shared.setTestSeams(
            scriptRunner: nil, ineligibility: nil,
            stalenessReader: { "99.0.0" }, stalenessSink: { sink.lines.append($0) })
        await MailController.shared.resetStalenessGateForTesting()

        _ = try? await MailController.shared.runScriptAsList("return {}")

        XCTAssertEqual(sink.lines.count, 1,
            "a drifted sidecar must warn when a real AppleScript entry point runs its "
            + "preflight — if this is 0, the wiring was removed from preflightAutomation()")
        XCTAssertTrue(sink.lines.first?.contains("99.0.0") == true)
        XCTAssertTrue(sink.lines.first?.lowercased().contains("restart") == true)
    }

    func testWarnsOnlyOnce_butKeepsCheckingUntilItWarns() async {
        let sink = Sink()
        var version = AppVersion.current          // start with no drift
        await MailController.shared.setTestSeams(
            scriptRunner: nil, ineligibility: nil,
            stalenessReader: { version }, stalenessSink: { sink.lines.append($0) })
        await MailController.shared.resetStalenessGateForTesting()

        await MailController.shared.runStalenessCheck()
        await MailController.shared.runStalenessCheck()
        XCTAssertEqual(sink.lines.count, 0, "no drift → silent, and the gate must stay armed")

        version = "99.0.0"                         // a newer binary lands on disk
        await MailController.shared.runStalenessCheck()
        XCTAssertEqual(sink.lines.count, 1, "the later drift must still be caught (B2)")

        await MailController.shared.runStalenessCheck()
        XCTAssertEqual(sink.lines.count, 1, "…but only warned about once")
    }

    func testNeverThrowsAndNeverBlocksTheCaller() async {
        // A hostile reader must not be able to make the check throw or refuse:
        // the invariant is that a stale server keeps working (post-#297) and is
        // merely nudged.
        let sink = Sink()
        await MailController.shared.setTestSeams(
            scriptRunner: nil, ineligibility: nil,
            stalenessReader: { "\u{1B}[2Jgarbage\nnot a version" },
            stalenessSink: { sink.lines.append($0) })
        await MailController.shared.resetStalenessGateForTesting()

        await MailController.shared.runStalenessCheck()   // must simply return
        XCTAssertEqual(sink.lines.count, 0, "unparseable input fails open — no warning, no throw")
    }

    private final class Sink: @unchecked Sendable { var lines: [String] = [] }

    // MARK: - #7: the handshake version cannot silently re-rot
    //
    // This one legitimately stays a source assertion: it is a statement about
    // what the source SAYS (no hardcoded literal), not about what executes, so
    // reading the text is the right instrument. The version actually reported
    // at runtime is covered separately by VersionTests.

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
