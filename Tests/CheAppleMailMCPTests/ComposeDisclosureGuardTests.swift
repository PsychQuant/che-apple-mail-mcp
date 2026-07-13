import XCTest

/// #237 — source-invariant guard: the compose_email / create_draft tool schemas
/// must DISCLOSE the legacy-path consequence (body wrapped in
/// `<blockquote type="cite">`, renders quoted on some mobile clients).
///
/// The 2026-07-09 regression report happened because every wrapper-relevant
/// fact lived outside the calling agent's view: `from_address` silently forced
/// the legacy injection path (#131 disqualifier, clean path pending #219) and
/// neither the result string nor the parameter description said so. The result
/// string is covered by unit tests (`legacyPathDisclosure`); this guard pins
/// the SCHEMA side so a future description rewrite can't silently drop the
/// warning again.
final class ComposeDisclosureGuardTests: XCTestCase {

    private func serverSwiftSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <package root>/
            .appendingPathComponent("Sources/CheAppleMailMCP/Server.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every `from_address` parameter description must warn that using it
    /// forces the legacy (wrapped-body) path until #219 lands.
    func testFromAddressDescriptions_discloseLegacyPathAnd219() throws {
        let source = try serverSwiftSource()
        let lines = source.components(separatedBy: "\n")
        let fromAddressLines = lines.filter { $0.contains("\"from_address\": .object") }
        XCTAssertGreaterThanOrEqual(fromAddressLines.count, 2,
            "expected from_address schema entries for compose_email + create_draft")
        for line in fromAddressLines {
            XCTAssertTrue(line.contains("legacy"),
                "from_address description must disclose the legacy-path consequence: \(line.prefix(160))")
            XCTAssertTrue(line.contains("#219"),
                "from_address description must reference the #219 clean-path follow-up: \(line.prefix(160))")
        }
    }

    /// The compose_email / create_draft `format` descriptions must disclose
    /// that markdown/html route to the legacy (wrapped) path. The
    /// "passes body as-is" phrase appears exactly on those two lines.
    func testComposeFormatDescriptions_discloseWrapperTradeoff() throws {
        let source = try serverSwiftSource()
        let lines = source.components(separatedBy: "\n")
        let formatLines = lines.filter { $0.contains("passes body as-is") }
        XCTAssertGreaterThanOrEqual(formatLines.count, 2,
            "expected format schema entries for compose_email + create_draft")
        for line in formatLines {
            XCTAssertTrue(line.contains("wrapper-free") || line.contains("legacy"),
                "format description must disclose the plain-only wrapper-free trade-off: \(line.prefix(160))")
        }
    }

    /// The compose_email / create_draft tool descriptions must state the
    /// wrapper-free eligibility conditions so a calling agent can route
    /// BEFORE creating a wrapped draft (not discover it afterwards).
    func testToolDescriptions_stateWrapperFreeEligibility() throws {
        let source = try serverSwiftSource()
        let lines = source.components(separatedBy: "\n")
        for tool in ["compose_email", "create_draft"] {
            guard let nameIdx = lines.firstIndex(where: { $0.contains("name: \"\(tool)\"") }) else {
                XCTFail("tool \(tool) not found in Server.swift")
                continue
            }
            let window = lines[nameIdx..<min(nameIdx + 3, lines.count)].joined(separator: "\n")
            XCTAssertTrue(window.lowercased().contains("wrapper-free"),
                "\(tool) tool description must mention the wrapper-free path: \(window.prefix(240))")
            // #237 verify DA-6: pin the ELIGIBILITY LIST itself, not just the
            // phrase — a rewrite keeping "wrapper-free" but dropping the
            // conditions would otherwise still pass this guard (the same
            // silent-drop failure mode #237 is about, one level up).
            for condition in ["plain", "subject", "from_address",
                              "Accessibility", "CHE_MAIL_DISABLE_MAILTO_COMPOSE"] {
                XCTAssertTrue(window.contains(condition),
                    "\(tool) tool description must state eligibility condition '\(condition)': \(window.prefix(240))")
            }
        }
    }
}
