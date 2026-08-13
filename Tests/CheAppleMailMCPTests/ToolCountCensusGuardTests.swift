import XCTest
@testable import CheAppleMailMCP

/// #248 — tool-count census guard. `defineTools().count` is the single source
/// of truth; every documented count claim and both README tool tables must
/// match it, so a newly added tool can never silently drift the docs again
/// (the pre-#233 state: README said 47/48/49 while the server shipped 51).
final class ToolCountCensusGuardTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CheAppleMailMCPTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    private var actualCount: Int { CheAppleMailMCPServer.defineTools().count }

    private var actualNames: Set<String> {
        Set(CheAppleMailMCPServer.defineTools().map(\.name))
    }

    /// Extract every claimed tool count from a document via the given regex
    /// patterns (each pattern's first capture group must be the number).
    private func claimedCounts(in text: String, patterns: [String]) throws -> [Int] {
        var counts: [Int] = []
        for pattern in patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, match.numberOfRanges > 1,
                      let r = Range(match.range(at: 1), in: text) else { return }
                counts.append(Int(text[r]) ?? -1)
            }
        }
        return counts
    }

    /// Tool names appearing as `| `name` |` rows, scoped to the collapsible
    /// tool-section blocks (`<details><summary><b>Section (N)</b>…`) so field
    /// tables elsewhere in the docs (e.g. the #204 truncation-envelope table)
    /// are not mistaken for tool rows.
    private func tabledNames(in text: String) throws -> [String] {
        let sectionRegex = try NSRegularExpression(
            pattern: #"<summary><b>[^<]+ \(\d+\)</b></summary>(.*?)</details>"#,
            options: [.dotMatchesLineSeparators])
        let rowRegex = try NSRegularExpression(pattern: #"^\| `([a-z0-9_]+)` \|"#,
                                               options: [.anchorsMatchLines])
        var names: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        sectionRegex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let bodyRange = Range(match.range(at: 1), in: text) else { return }
            let body = String(text[bodyRange])
            let bodyNSRange = NSRange(body.startIndex..., in: body)
            rowRegex.enumerateMatches(in: body, range: bodyNSRange) { row, _, _ in
                guard let row, let r = Range(row.range(at: 1), in: body) else { return }
                names.append(String(body[r]))
            }
        }
        return names
    }

    /// `<summary><b>Section (N)</b></summary>` header counts.
    private func sectionCounts(in text: String) throws -> [Int] {
        try claimedCounts(in: text,
                          patterns: [#"<summary><b>[^<]+ \((\d+)\)</b></summary>"#])
    }

    /// Per-section (header-claimed N, actual tool-row count, section name).
    /// Guards each section individually so a compensating +1/−1 pair across two
    /// sections cannot pass the aggregate sum check (verify #248, Codex LOW).
    private func sectionHeaderVsRows(in text: String) throws -> [(name: String, claimed: Int, rows: Int)] {
        let sectionRegex = try NSRegularExpression(
            pattern: #"<summary><b>([^<]+) \((\d+)\)</b></summary>(.*?)</details>"#,
            options: [.dotMatchesLineSeparators])
        let rowRegex = try NSRegularExpression(pattern: #"^\| `[a-z0-9_]+` \|"#,
                                               options: [.anchorsMatchLines])
        var result: [(String, Int, Int)] = []
        let range = NSRange(text.startIndex..., in: text)
        sectionRegex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let nameRange = Range(match.range(at: 1), in: text),
                  let claimedRange = Range(match.range(at: 2), in: text),
                  let bodyRange = Range(match.range(at: 3), in: text) else { return }
            let body = String(text[bodyRange])
            let rows = rowRegex.numberOfMatches(
                in: body, range: NSRange(body.startIndex..., in: body))
            result.append((String(text[nameRange]), Int(text[claimedRange]) ?? -1, rows))
        }
        return result
    }

    private func assertSectionHeadersMatchRows(file relativePath: String) throws {
        let sections = try sectionHeaderVsRows(in: try read(relativePath))
        XCTAssertFalse(sections.isEmpty)
        for section in sections {
            XCTAssertEqual(section.claimed, section.rows,
                           "\(relativePath) section '\(section.name)' header claims "
                           + "\(section.claimed) tools but tables \(section.rows)")
        }
    }

    func testReadme_eachSectionHeader_matchesItsRowCount() throws {
        try assertSectionHeadersMatchRows(file: "README.md")
    }

    func testReadmeZh_eachSectionHeader_matchesItsRowCount() throws {
        try assertSectionHeadersMatchRows(file: "README_zh-TW.md")
    }

    // MARK: README.md (English)

    func testReadme_countClaims_matchDefineTools() throws {
        let text = try read("README.md")
        let claims = try claimedCounts(in: text, patterns: [
            #"- (\d+) tools with"#,
            #"## All (\d+) Tools"#,
            #"\| Total Tools \| ~20 \| \*\*(\d+)\*\*"#,
        ])
        XCTAssertEqual(claims.count, 3, "expected all three README.md count claims to be found")
        for claim in claims {
            XCTAssertEqual(claim, actualCount,
                           "README.md claims \(claim) tools; defineTools() has \(actualCount)")
        }
    }

    func testReadme_sectionSubcounts_sumToDefineTools() throws {
        let text = try read("README.md")
        let sections = try sectionCounts(in: text)
        XCTAssertFalse(sections.isEmpty)
        XCTAssertEqual(sections.reduce(0, +), actualCount,
                       "README.md section sub-counts \(sections) must sum to \(actualCount)")
    }

    func testReadme_tabledToolNames_exactlyDefineTools() throws {
        let names = try tabledNames(in: try read("README.md"))
        XCTAssertEqual(names.count, Set(names).count, "duplicate rows in README.md tool tables")
        XCTAssertEqual(Set(names), actualNames,
                       "missing: \(actualNames.subtracting(names).sorted()); "
                       + "extra: \(Set(names).subtracting(actualNames).sorted())")
    }

    // MARK: README_zh-TW.md

    func testReadmeZh_countClaims_matchDefineTools() throws {
        let text = try read("README_zh-TW.md")
        let claims = try claimedCounts(in: text, patterns: [
            #"- (\d+) 個工具"#,
            #"## 全部 (\d+) 個工具"#,
            #"\| 工具總數 \| ~20 \| \*\*(\d+)\*\*"#,
        ])
        XCTAssertEqual(claims.count, 3, "expected all three README_zh-TW.md count claims to be found")
        for claim in claims {
            XCTAssertEqual(claim, actualCount,
                           "README_zh-TW.md claims \(claim) tools; defineTools() has \(actualCount)")
        }
    }

    func testReadmeZh_tabledToolNames_exactlyDefineTools() throws {
        let names = try tabledNames(in: try read("README_zh-TW.md"))
        XCTAssertEqual(names.count, Set(names).count, "duplicate rows in README_zh-TW.md tool tables")
        XCTAssertEqual(Set(names), actualNames,
                       "missing: \(actualNames.subtracting(names).sorted()); "
                       + "extra: \(Set(names).subtracting(actualNames).sorted())")
    }

    func testReadmeZh_sectionSubcounts_sumToDefineTools() throws {
        let text = try read("README_zh-TW.md")
        let sections = try sectionCounts(in: text)
        XCTAssertFalse(sections.isEmpty)
        XCTAssertEqual(sections.reduce(0, +), actualCount,
                       "README_zh-TW.md section sub-counts \(sections) must sum to \(actualCount)")
    }

    // MARK: server.json + mcpb/manifest.json

    func testServerJson_countClaim_matchesDefineTools() throws {
        let claims = try claimedCounts(in: try read("server.json"),
                                       patterns: [#"(\d+) tools"#])
        XCTAssertFalse(claims.isEmpty, "server.json description should state the tool count")
        for claim in claims { XCTAssertEqual(claim, actualCount) }
    }

    func testManifestJson_countClaims_matchDefineTools() throws {
        let claims = try claimedCounts(in: try read("mcpb/manifest.json"),
                                       patterns: [#"(\d+) tools"#])
        XCTAssertEqual(claims.count, 2, "manifest.json states the count in description + long_description")
        for claim in claims { XCTAssertEqual(claim, actualCount) }
    }
}

/// #348 — the manifest's `tools` array had rotted exactly the way its `version`
/// field did before #311: no owner, so it drifted silently. Measured at the
/// time: 47 listed, 53 registered, six missing — the three TCC probes
/// (`check_fda` / `check_accessibility` / `check_automation`), `update_draft`,
/// and BOTH names of the batch export. The packaged `.mcpb` (the Claude Desktop
/// install path) therefore advertised an incomplete tool surface.
///
/// `ToolCountCensusGuardTests` did not catch it because it pins a *count string*
/// in prose. The array could drift arbitrarily while the census stayed green —
/// the same shape of gap, one field over.
///
/// This asserts **set equality in both directions**, so a removed tool fails
/// just as loudly as an added one. That closes the field rather than the
/// instance, which is the general form of #311's lesson.
final class ManifestToolsSetEqualityTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Set `REGENERATE_MCPB_MANIFEST=1` to rewrite the array from
    /// `defineTools()` instead of asserting against it. A golden file, because
    /// the alternative — scraping `Server.swift` for `Tool(name:description:)`
    /// literals — is what produced the first version of this fix, and it
    /// silently mangled six entries: descriptions assembled from concatenated
    /// literals were missed entirely (`batch_export_emails_markdown` ended up
    /// with its own NAME as its description) and the rest were cut mid-word.
    /// The registered tools are the authority, so read them, don't re-derive
    /// them from their source text.
    func testManifestToolsMatchRegisteredToolsExactly() throws {
        let url = Self.repoRoot.appendingPathComponent("mcpb/manifest.json")
        let registered = CheAppleMailMCPServer.defineTools()

        if ProcessInfo.processInfo.environment["REGENERATE_MCPB_MANIFEST"] == "1" {
            var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any] ?? [:]
            root["tools"] = registered
                .sorted { $0.name < $1.name }
                .map { ["name": $0.name, "description": $0.description ?? ""] }
            let out = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try (String(data: out, encoding: .utf8)! + "\n").write(to: url, atomically: true, encoding: .utf8)
            print("regenerated mcpb/manifest.json tools[] from \(registered.count) registered tools")
            return
        }

        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = (json?["tools"] as? [[String: Any]]) ?? []
        let manifest = Set(entries.compactMap { $0["name"] as? String })
        let registeredNames = Set(registered.map(\.name))

        XCTAssertEqual(entries.count, manifest.count,
                       "duplicate tool names in mcpb/manifest.json")

        let missing = registeredNames.subtracting(manifest).sorted()
        let extra = manifest.subtracting(registeredNames).sorted()

        XCTAssertTrue(missing.isEmpty,
            "registered but ABSENT from mcpb/manifest.json — the packaged .mcpb would "
            + "advertise an incomplete tool surface: \(missing)")
        XCTAssertTrue(extra.isEmpty,
            "listed in mcpb/manifest.json but NOT registered — the .mcpb advertises tools "
            + "that do not exist: \(extra)")

        // Names alone were not enough: the array's DESCRIPTIONS could still rot
        // (or arrive truncated) while the name set stayed perfect, which is the
        // same "owner for one field, none for the neighbour" shape as #311 and
        // as this issue. Regenerate with REGENERATE_MCPB_MANIFEST=1.
        var descriptionMismatches: [String] = []
        let byName = Dictionary(uniqueKeysWithValues: registered.map { ($0.name, $0.description ?? "") })
        for entry in entries {
            guard let name = entry["name"] as? String, let want = byName[name] else { continue }
            let got = entry["description"] as? String
            if got != want {
                descriptionMismatches.append(
                    "\(name): manifest has \(got.map { "\"\($0.prefix(60))…\"" } ?? "no description"), "
                    + "registered is \"\(want.prefix(60))…\"")
            }
        }
        XCTAssertTrue(descriptionMismatches.isEmpty,
            "mcpb/manifest.json descriptions differ from the registered tools "
            + "(re-run with REGENERATE_MCPB_MANIFEST=1):\n"
            + descriptionMismatches.joined(separator: "\n"))
    }
}
