import XCTest

/// #237/#304 — source-invariant guard on what the compose_email / create_draft
/// schemas TELL a calling agent. #237 installed it to make the legacy path's
/// consequence visible; #304 deleted that path, so the same guard now pins the
/// replacement contract: plain-only, and the six refusal conditions stated up
/// front.
///
/// The 2026-07-09 regression report happened because every wrapper-relevant
/// fact lived outside the calling agent's view: `from_address` silently forced
/// the legacy injection path and neither the result string nor the parameter
/// description said so. The schema is what the agent reads before it calls, so
/// a description rewrite must not be able to silently drop what it needs.
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
            XCTAssertFalse(line.contains("legacy"),
                "#304: there is no legacy path left to route to: \(line.prefix(160))")
            XCTAssertTrue(line.contains("#219"),
                "from_address description must reference the verified From popup (#219): \(line.prefix(160))")
        }
    }

    /// The `format` description must say plain is the only value and must not
    /// go on advertising markdown/html as usable. Pinned as a source invariant
    /// because the schema text is what a calling agent reads BEFORE it calls —
    /// the same reasoning #237 used, applied to the removal.
    func testFormatDescriptions_advertisePlainOnly() throws {
        let source = try serverSwiftSource()
        let lines = source.components(separatedBy: "\n")
        let formatLines = lines.filter { $0.contains("\"format\": .object") && $0.contains("enum") }
        XCTAssertGreaterThanOrEqual(formatLines.count, 5,
            "expected format schema entries for the five composing tools")
        for line in formatLines {
            XCTAssertTrue(line.contains(".string(\"plain\")"), line.prefix(160).description)
            XCTAssertFalse(line.contains(".string(\"markdown\")"),
                "format enum must no longer offer markdown (#304): \(line.prefix(160))")
            XCTAssertFalse(line.contains(".string(\"html\")"),
                "format enum must no longer offer html (#304): \(line.prefix(160))")
            XCTAssertTrue(line.contains("ONLY supported"),
                "the description must say plain is the only supported value: \(line.prefix(160))")
        }
    }

    /// The compose_email / create_draft tool descriptions must state the
    /// refusal conditions, so a calling agent can fix the call BEFORE it fails
    /// rather than discovering the conditions from an error. This is the same
    /// guard #237 installed, re-aimed: what used to need disclosing was a
    /// silent degradation, and what needs stating now is a refusal.
    func testToolDescriptions_stateTheRefusalConditions() throws {
        let source = try serverSwiftSource()
        let lines = source.components(separatedBy: "\n")
        for tool in ["compose_email", "create_draft"] {
            guard let nameIdx = lines.firstIndex(where: { $0.contains("name: \"\(tool)\"") }) else {
                XCTFail("tool \(tool) not found in Server.swift")
                continue
            }
            let window = lines[nameIdx..<min(nameIdx + 3, lines.count)].joined(separator: "\n")
            // Pin the CONDITION LIST, not just a phrase (#237 verify DA-6: a
            // rewrite keeping the phrase but dropping the conditions would
            // otherwise pass — the same silent-drop failure one level up).
            for condition in ["'plain'", "subject", "from_address", "Accessibility",
                              "open_mailto", "non-ASCII", "display name"] {
                XCTAssertTrue(window.contains(condition),
                    "\(tool) description must state refusal condition '\(condition)': \(window.prefix(240))")
            }
            XCTAssertTrue(window.contains("FAILS"),
                "\(tool) description must say the call fails rather than degrades: \(window.prefix(240))")
            XCTAssertTrue(window.contains("six"),
                "\(tool) description must state the enumeration is closed at six: \(window.prefix(240))")
        }
    }
}
