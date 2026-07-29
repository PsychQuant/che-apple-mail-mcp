import XCTest
@testable import CheAppleMailMCP

/// #303 verify #5/#7 — source guards for wiring that behavioural tests cannot
/// reach.
///
/// `preflightAutomation()` is `private` on an `actor`, so no unit test can call
/// it. Before this guard, deleting the staleness wiring from it left the entire
/// suite green — which is precisely how B1 and B2 survived three independent
/// PASS verdicts. Following the repo's existing `*GuardTests` convention
/// (ComposeDisclosure / NoContentContainsScan / ReplyForwardDisclosure /
/// ToolCountCensus).
final class StalenessWiringGuardTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <package root>/
            .appendingPathComponent("Sources/CheAppleMailMCP")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: root, encoding: .utf8)
    }

    // MARK: - #5: the staleness check is actually wired into the chokepoint

    func testPreflightAutomation_stillInvokesTheStalenessCheck() throws {
        let src = try source("AppleScript/MailController.swift")

        guard let preflightRange = src.range(of: "private func preflightAutomation() throws -> Bool {") else {
            return XCTFail("preflightAutomation() not found — this guard's anchor moved; re-point it")
        }
        // Body runs from the signature to the next top-level member.
        let body = src[preflightRange.lowerBound...].prefix(1200)

        XCTAssertTrue(body.contains("stalenessWarningOnce"),
            "the staleness check must remain wired into preflightAutomation — the chokepoint "
            + "every AppleScript-backed tool passes through. Deleting it used to leave the "
            + "whole suite green (#303 verify finding #5).")
        XCTAssertTrue(body.contains("didWarnStaleness"),
            "must use the warn-once flag; a check-once flag is defect B2 (the gate gets "
            + "consumed at startup before any drift can exist)")
    }

    /// B1: the read must never regress to a convenience API. `String(contentsOf:)`
    /// is unbounded and this call site sits outside #297's guard.
    func testSidecarRead_usesBoundedSyscallsNotStringContentsOf() throws {
        let src = try source("AppleScript/MailController.swift")

        guard let range = src.range(of: "static func readVersionSidecar(at path: String) -> String? {") else {
            return XCTFail("readVersionSidecar(at:) not found — re-point this guard")
        }
        let body = src[range.lowerBound...].prefix(1200)

        XCTAssertTrue(body.contains("O_NOFOLLOW"), "must refuse a planted symlink")
        XCTAssertTrue(body.contains("O_NONBLOCK"), "must not block on a FIFO")
        XCTAssertTrue(body.contains("fstat"), "must verify it is a regular file")
        XCTAssertFalse(body.contains("String(contentsOf"),
            "must NOT use the unbounded convenience read here — it runs outside #297's "
            + "runGuarded on the singleton actor's serial executor (#303 verify B1)")
    }

    // MARK: - #7: the handshake version cannot silently re-rot

    func testServer_reportsAppVersionNotAHardcodedLiteral() throws {
        let src = try source("Server.swift")

        XCTAssertTrue(src.contains("version: AppVersion.current"),
            "the MCP handshake must report AppVersion.current — it was hardcoded \"2.7.2\" "
            + "for ~18 releases before #303")

        // No hardcoded x.y.z literal in a `version:` argument position.
        let hardcoded = try NSRegularExpression(pattern: #"version:\s*"\d+\.\d+\.\d+""#)
        let ns = src as NSString
        XCTAssertEqual(
            hardcoded.numberOfMatches(in: src, range: NSRange(location: 0, length: ns.length)), 0,
            "a hardcoded version literal reintroduces the rot AppVersion.current exists to prevent")
    }
}
