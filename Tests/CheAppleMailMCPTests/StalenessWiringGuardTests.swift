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
        return Self.strippingComments(try String(contentsOf: root, encoding: .utf8))
    }

    /// Remove `//` and `/* */` comments before any `contains` check.
    ///
    /// Without this the guards were defeated by *commenting the wiring out*
    /// rather than deleting it: the identifiers survive inside the comment, so
    /// a lexical `contains` still matched and the guard passed on code that no
    /// longer ran (#303 verify round 2). Deleting the lines was the only
    /// mutation the guards were originally proven against — which is exactly
    /// the blind spot: a guard tested only against the mutation its author
    /// imagined is calibrated to that imagination, not to the defect class.
    ///
    /// Deliberately simple: this is a guard over our own source, not a Swift
    /// lexer. It does not model string literals containing comment markers —
    /// acceptable because a false *failure* is loud and immediately fixable,
    /// whereas the false *pass* it replaces was silent.
    static func strippingComments(_ source: String) -> String {
        var out = ""
        var inBlock = false, inLine = false, i = source.startIndex
        while i < source.endIndex {
            let c = source[i]
            let next = source.index(after: i)
            let pair = next < source.endIndex ? String([c, source[next]]) : ""

            if inLine {
                if c == "\n" { inLine = false; out.append(c) }
            } else if inBlock {
                if pair == "*/" { inBlock = false; i = next }
            } else if pair == "//" {
                inLine = true; i = next
            } else if pair == "/*" {
                inBlock = true; i = next
            } else {
                out.append(c)
            }
            i = source.index(after: i)
        }
        return out
    }

    /// Extract a function body by BRACE BALANCING from its signature, rather
    /// than a fixed-size character window. A fixed window silently stops
    /// covering the thing it guards once the function grows past it, and can
    /// also over-run into unrelated following members — both failure modes are
    /// silent false-passes (#303 verify round 2).
    static func functionBody(_ source: String, startingWith signature: String) -> String? {
        guard let sigRange = source.range(of: signature),
              let openBrace = source[sigRange.lowerBound...].firstIndex(of: "{")
        else { return nil }

        var depth = 0
        var i = openBrace
        while i < source.endIndex {
            if source[i] == "{" { depth += 1 }
            if source[i] == "}" {
                depth -= 1
                if depth == 0 { return String(source[openBrace...i]) }
            }
            i = source.index(after: i)
        }
        return nil   // unbalanced — treat as not found, caller fails loudly
    }

    // MARK: - the comment-stripper itself must work (it is load-bearing)

    func testStripsBothCommentForms() {
        let stripped = Self.strippingComments("""
        keep1
        // gone_line
        keep2 /* gone_block */ keep3
        /*
        gone_multiline
        */
        keep4
        """)
        XCTAssertTrue(stripped.contains("keep1") && stripped.contains("keep2")
                      && stripped.contains("keep3") && stripped.contains("keep4"))
        for gone in ["gone_line", "gone_block", "gone_multiline"] {
            XCTAssertFalse(stripped.contains(gone), "'\(gone)' must not survive stripping")
        }
    }

    // MARK: - #5: the staleness check is actually wired into the chokepoint

    func testPreflightAutomation_stillInvokesTheStalenessCheck() throws {
        let src = try source("AppleScript/MailController.swift")

        guard let body = Self.functionBody(src, startingWith: "private func preflightAutomation() throws -> Bool") else {
            return XCTFail("preflightAutomation() not found — this guard's anchor moved; re-point it")
        }

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

        guard let body = Self.functionBody(src, startingWith: "static func readVersionSidecar(at path: String) -> String?") else {
            return XCTFail("readVersionSidecar(at:) not found — re-point this guard")
        }

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
