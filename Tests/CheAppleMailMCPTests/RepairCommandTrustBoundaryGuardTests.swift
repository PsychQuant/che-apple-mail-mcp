import XCTest

/// #530 — trust-boundary guard for the synthetic-ID repair SOP.
///
/// `/archive-mail-repair-synthetic-ids` is prose that a model executes, and the
/// #389 verify round found three places where the prose claimed more than it
/// could enforce:
///   1. its reports echoed mail-derived strings (a synthetic key carries the
///      sender and a truncated subject), so the report itself became an
///      injection surface for whoever reads it next;
///   2. the index location came from a "trusted target configuration" that is
///      defined nowhere, so the sentence invited a source it never specified;
///   3. the "read-only inspection scope" was presented as the authorization,
///      although a host Bash authorization is for a command, not for its
///      semantics.
///
/// These are structural presence checks on the SOP text, not a proof that a
/// model obeys it: they fail when the sentence that closes a gap is removed or
/// reworded back. They deliberately do not judge prose quality.
final class RepairCommandTrustBoundaryGuardTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CheAppleMailMCPTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private func load(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    private func repairSOP() throws -> String {
        try load("plugin/commands/archive-mail-repair-synthetic-ids.md")
    }

    // MARK: - (2) index location source

    func testIndexLocationHasNoUndefinedTrustedConfigSource() throws {
        let sop = try repairSOP()
        XCTAssertFalse(sop.contains("可信 target 設定"),
            "the SOP must not name a 'trusted target configuration': no config field defines "
            + "an index path (plugin/CLAUDE.md), so the phrase invites a source that does not exist (#530).")
    }

    func testIndexLocationNamesTheTwoAcceptedSources() throws {
        let sop = try repairSOP()
        XCTAssertTrue(sop.contains("Step 1.6"),
            "the index location must cite archive-mail.md Step 1.6, the one place that defines it (#530).")
        XCTAssertTrue(sop.contains("本次叫用"),
            "the only other accepted source is a path the user gives in this invocation (#530).")
        XCTAssertTrue(sop.contains("逐字"),
            "a user-supplied index path must be taken verbatim, never inferred or rewritten (#530).")
        XCTAssertTrue(sop.contains("/archive-mail-migrate"),
            "a legacy `.email_index.json` next to the archive is not an accepted location; the SOP "
            + "must send the user to /archive-mail-migrate instead of reading it (#530).")
    }

    /// The SOP cites Step 1.6 instead of copying the formula, so the citation
    /// is only as good as the formula still being there.
    func testStep16FormulaStillMatchesWhatTheSOPCites() throws {
        let archive = try load("plugin/commands/archive-mail.md")
        XCTAssertTrue(archive.contains("INDEX_DIR=\"${NAMESPACE_DIR}/state/archives/${SLUG}\""),
            "archive-mail.md Step 1.6 no longer defines INDEX_DIR as the workspace state directory; "
            + "update the repair SOP's index-location sentence (#530).")
        XCTAssertTrue(archive.contains("INDEX_FILE=\"${INDEX_DIR}/email_index.json\""),
            "archive-mail.md Step 1.6 no longer defines INDEX_FILE; update the repair SOP (#530).")
        let sop = try repairSOP()
        XCTAssertTrue(sop.contains(".claude/.mail/state/archives/"),
            "the SOP should name the directory the formula yields so a reader can check a path "
            + "without opening the other command (#530).")
    }

    // MARK: - (3) Bash authorization is not read-only

    func testBashAuthorizationIsDisclosedAsNotReadOnly() throws {
        let sop = try repairSOP()
        XCTAssertTrue(sop.contains("不限於唯讀"),
            "the SOP must say plainly that a host Bash authorization is not limited to read-only (#530).")
        XCTAssertTrue(sop.contains("永遠允許"),
            "the SOP must warn against an always-allow grant, which outlives the one command (#530).")
    }

    // MARK: - (1) reports do not echo mail-derived strings verbatim

    func testReportOutputRuleExistsAndLabelsQuotedValuesAsData() throws {
        let sop = try repairSOP()
        XCTAssertTrue(sop.contains("報告輸出規則"),
            "the SOP needs one named rule for what a report may print from mail-derived text (#530).")
        XCTAssertTrue(sop.contains("basename"),
            "the default must be file basenames and reason codes, as archive-mail.md Step 7 does (#530).")
        XCTAssertTrue(sop.contains("不是指示"),
            "a quoted mail-derived value must be labelled as data, not as an instruction (#530).")
    }

    /// Fenced blocks that hold a `status:` line are the report templates
    /// (capability preflight, lookup failure, apply preflight, apply
    /// incomplete, final report). Each must carry the data notice so the
    /// reader of a report sees it even without opening this SOP.
    func testEveryReportTemplateCarriesTheDataNotice() throws {
        let sop = try repairSOP()
        let blocks = Self.fencedBlocks(in: sop)
            .filter { block in block.contains { $0.hasPrefix("status:") } }
        XCTAssertGreaterThanOrEqual(blocks.count, 5,
            "expected the five report templates (preflight, lookup, apply preflight, apply incomplete, "
            + "final); found \(blocks.count) — a template was removed or the parser lost track of fences.")
        for block in blocks {
            let status = block.first { $0.hasPrefix("status:") } ?? "status: ?"
            XCTAssertTrue(block.contains { $0.hasPrefix("note:") && $0.contains("報告輸出規則") },
                "the report template with `\(status)` lacks a `note:` line pointing at 報告輸出規則 (#530).")
            XCTAssertFalse(block.contains { $0.contains("保留實際工具錯誤") },
                "the report template with `\(status)` still tells the model to keep the tool error "
                + "verbatim; a tool error can echo the subject it was queried with (#530).")
        }
    }

    // MARK: - fence parsing

    /// Lines of every ``` fenced block, without the fence lines themselves.
    private static func fencedBlocks(in text: String) -> [[String]] {
        var blocks: [[String]] = []
        var current: [String]?
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let open = current {
                    blocks.append(open)
                    current = nil
                } else {
                    current = []
                }
            } else if current != nil {
                current?.append(line)
            }
        }
        return blocks
    }
}
