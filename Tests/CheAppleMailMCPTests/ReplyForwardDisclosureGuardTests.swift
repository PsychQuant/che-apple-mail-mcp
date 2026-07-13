import XCTest

/// #229 — source-invariant guard: the reply_email / forward_email tool schemas
/// must DISCLOSE the clean new-body path (#218) eligibility conditions and the
/// legacy-path consequence (NEW body wrapped in `<blockquote type="cite">`,
/// renders quoted on some mobile clients; the quoted ORIGINAL's cite block is
/// the legitimate structure Mail builds).
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
            for condition in ["plain", "Accessibility", "CHE_MAIL_DISABLE_PASTE_REPLY", "legacy"] {
                XCTAssertTrue(window.contains(condition),
                    "\(tool) tool description must state clean-path condition/consequence '\(condition)': \(window.prefix(240))")
            }
            // #229 verify round: pin the conjunction phrasing too, so a rewrite
            // can't keep the keywords but drop the "all conditions required"
            // semantics (or the env-unset direction).
            XCTAssertTrue(window.contains("ALL hold"),
                "\(tool) description must state the ALL-hold conjunction: \(window.prefix(240))")
            XCTAssertTrue(window.contains("not set"),
                "\(tool) description must state the env-unset direction: \(window.prefix(240))")
        }
    }

    /// forward_email must additionally disclose that a forward WITHOUT a body
    /// is always wrapper-free (no disclosure suffix will ever be appended).
    func testForwardDescription_notesBodylessForwardIsWrapperFree() throws {
        let source = try serverSwiftSource()
        let lines = source.components(separatedBy: "\n")
        guard let nameIdx = lines.firstIndex(where: { $0.contains("name: \"forward_email\"") }) else {
            XCTFail("forward_email not found"); return
        }
        let window = lines[nameIdx..<min(nameIdx + 3, lines.count)].joined(separator: "\n")
        XCTAssertTrue(window.contains("wrapper-free"),
            "forward_email description must note the bodyless forward is wrapper-free: \(window.prefix(240))")
    }
}
