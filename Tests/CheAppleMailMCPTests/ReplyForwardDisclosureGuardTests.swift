import XCTest

/// #229/#304 — source-invariant guard: the reply_email / forward_email tool
/// schemas must state the conditions under which the call is REFUSED, so a
/// calling agent can fix the call before it fails. #229 installed this to
/// disclose a silent degradation; #304 removed the path that degraded, so the
/// same guard now pins the refusal contract.
///
/// Sibling of PR #240's ComposeDisclosureGuardTests (compose family) — kept as
/// a separate file so the two branches don't conflict; consolidation after both
/// merge is optional. Condition-level asserts from the start (#237 verify DA-6
/// lesson: a phrase-only guard lets a description rewrite silently drop the
/// eligibility list).
final class ReplyForwardDisclosureGuardTests: XCTestCase {

    private func serverSwiftSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <package root>/
            .appendingPathComponent("Sources/CheAppleMailMCP/Server.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The reply_email / forward_email tool descriptions must state the clean
    /// new-body path eligibility conditions so a calling agent can route
    /// BEFORE the reply lands with a wrapped new body.
    func testReplyForwardToolDescriptions_stateCleanPathEligibility() throws {
        let source = try serverSwiftSource()
        let lines = source.components(separatedBy: "\n")
        for tool in ["reply_email", "forward_email"] {
            guard let nameIdx = lines.firstIndex(where: { $0.contains("name: \"\(tool)\"") }) else {
                XCTFail("tool \(tool) not found in Server.swift")
                continue
            }
            let window = lines[nameIdx..<min(nameIdx + 3, lines.count)].joined(separator: "\n")
            for condition in ["'plain'", "Accessibility"] {
                XCTAssertTrue(window.contains(condition),
                    "\(tool) description must state refusal condition '\(condition)': \(window.prefix(240))")
            }
            XCTAssertTrue(window.contains("Two reasons"),
                "\(tool) description must state that exactly two reasons apply here: \(window.prefix(240))")
            XCTAssertFalse(window.contains("CHE_MAIL_DISABLE_PASTE_REPLY"),
                "#304: the env hatch is gone: \(window.prefix(240))")
        }
    }

    /// forward_email must additionally state that a forward WITHOUT a body
    /// assigns nothing and therefore needs no Accessibility grant — otherwise a
    /// calling agent reading "Accessibility required" would wrongly conclude the
    /// bare forward is unavailable to it.
    func testForwardDescription_notesBodylessForwardNeedsNoGrant() throws {
        let source = try serverSwiftSource()
        let lines = source.components(separatedBy: "\n")
        guard let nameIdx = lines.firstIndex(where: { $0.contains("name: \"forward_email\"") }) else {
            XCTFail("forward_email not found"); return
        }
        let window = lines[nameIdx..<min(nameIdx + 3, lines.count)].joined(separator: "\n")
        XCTAssertTrue(window.contains("assigns nothing"),
            "forward_email description must note the bodyless forward assigns nothing: \(window.prefix(240))")
        XCTAssertTrue(window.contains("needs no Accessibility"),
            "forward_email description must note it needs no grant: \(window.prefix(240))")
    }
}
