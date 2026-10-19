import XCTest

/// #311 — mcpb/manifest.json's `version` had no owner in the release pipeline
/// and froze at 2.7.2 for ~18 releases, masked because Server.swift's
/// then-hardcoded handshake version had rotted to the same value. This pins
/// the manifest to the newest released CHANGELOG header — the same invariant
/// `scripts/release.sh` now enforces at tag time — so the drift is caught in
/// CI between releases, not discovered by a user reading the bundle.
final class ManifestVersionTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
    }

    private func newestChangelogVersion() throws -> String {
        // #349: one shared parser (`scripts/changelog.py`). This used to be the
        // second of three independent readings of the same file — it required
        // three integer components while `VersionTests` went through `SemVer()`,
        // so a `## [2.27.0-rc1]` header made them measure different releases.
        let probe = try ChangelogParserTests.run(
            ["newest"], changelog: repoRoot().appendingPathComponent("CHANGELOG.md").path)
        guard probe.status == 0, !probe.out.isEmpty else {
            XCTFail("no released ## [x.y.z] header found in CHANGELOG.md")
            return ""
        }
        return probe.out
    }

    func testManifestVersionMatchesNewestRelease() throws {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("mcpb/manifest.json"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let manifestVersion = try XCTUnwrap(obj["version"] as? String,
                                            "mcpb/manifest.json must declare a version")
        let newest = try newestChangelogVersion()
        XCTAssertEqual(manifestVersion, newest,
            "mcpb/manifest.json version ('\(manifestVersion)') must match the newest released "
            + "CHANGELOG header ('\(newest)') — it froze at 2.7.2 for ~18 releases because "
            + "nothing owned it (#311). Bump it alongside the CHANGELOG at release prep.")
    }

    func testMarketplaceEntryVersionMatchesPluginManifest() throws {
        // #335 verify: the self-hosted marketplace re-declares the shell `version`
        // (the marketplace schema wants one per entry), so the pair can drift exactly
        // the way marketplace/plugin `binary_version` did in the aggregator era.
        // Pin them equal — and pin the deliberate ABSENCE of `binary_version` in the
        // marketplace entry, which is #335's load-bearing single-source decision.
        let root = repoRoot()
        let mktData = try Data(contentsOf: root.appendingPathComponent(".claude-plugin/marketplace.json"))
        let mkt = try XCTUnwrap(try JSONSerialization.jsonObject(with: mktData) as? [String: Any])
        let plugins = try XCTUnwrap(mkt["plugins"] as? [[String: Any]])
        let pjDataForName = try Data(contentsOf: root.appendingPathComponent("plugin/.claude-plugin/plugin.json"))
        let pjForName = try XCTUnwrap(try JSONSerialization.jsonObject(with: pjDataForName) as? [String: Any])
        let name = try XCTUnwrap(pjForName["name"] as? String)
        let matches = plugins.filter { ($0["name"] as? String) == name }
        XCTAssertEqual(matches.count, 1, "marketplace must contain exactly one entry for \(name)")
        let entry = try XCTUnwrap(matches.first, "marketplace.json must list the named plugin entry")
        let entryVersion = try XCTUnwrap(entry["version"] as? String)

        let pjData = try Data(contentsOf: root.appendingPathComponent("plugin/.claude-plugin/plugin.json"))
        let pj = try XCTUnwrap(try JSONSerialization.jsonObject(with: pjData) as? [String: Any])
        let pluginVersion = try XCTUnwrap(pj["version"] as? String)

        XCTAssertEqual(entryVersion, pluginVersion,
            "marketplace entry version ('\(entryVersion)') must equal plugin.json version "
            + "('\(pluginVersion)') — the shell version is declared in both manifests, and "
            + "an unowned duplicated field is exactly how the aggregator-era binary_version "
            + "drift happened (#335 verify).")
        XCTAssertNil(entry["binary_version"],
            "the marketplace entry must NOT declare binary_version — plugin.json is the "
            + "single source for the binary pin (#335's design decision).")
    }

    func testDescriptionsCarryNoVersionNarrative() throws {
        // #396: the 18.8KB description-as-changelog convention is dead — narrative
        // lives in plugin/CHANGELOG.md. Round-2 hardening (#400 verify): every
        // description-carrying surface must EXIST (a deleted key must not pass
        // vacuously), stay short, and carry no semver-shaped token at all — the
        // round-1 literal markers ("Shell v", "binary stays") only locked the
        // last incident's exact strings, not the class.
        let root = repoRoot()
        var inspected = 0

        func check(_ desc: String, at label: String) {
            inspected += 1
            XCTAssertFalse(desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(label): description is empty")
            XCTAssertLessThan(desc.utf8.count, 1000,
                "\(label): description is \(desc.utf8.count) UTF-8 bytes — narrative belongs in plugin/CHANGELOG.md (#396)")
            // Token-bounded so an IP address is not mistaken for a version.
            // The lookahead is (?!\.?[0-9A-Za-z]), NOT (?![0-9A-Za-z.]): the
            // latter let a version at the end of a sentence ("ships v2.28.0.")
            // escape the ban, because the trailing period satisfied it. Found
            // by mutation-testing this guard.
            XCTAssertNil(desc.range(of: #"(?<![0-9A-Za-z.])v?[0-9]+\.[0-9]+\.[0-9]+(?!\.?[0-9A-Za-z])"#,
                                    options: [.regularExpression, .caseInsensitive]),
                "\(label): description contains a semver-shaped token — any version claim here "
                + "starts lying the release after it was written (#396)")
        }

        let pjData = try Data(contentsOf: root.appendingPathComponent("plugin/.claude-plugin/plugin.json"))
        let pj = try XCTUnwrap(try JSONSerialization.jsonObject(with: pjData) as? [String: Any])
        check(try XCTUnwrap(pj["description"] as? String, "plugin.json must declare a description"),
              at: "plugin.json")

        let mktData = try Data(contentsOf: root.appendingPathComponent(".claude-plugin/marketplace.json"))
        let mkt = try XCTUnwrap(try JSONSerialization.jsonObject(with: mktData) as? [String: Any])
        check(try XCTUnwrap(mkt["description"] as? String, "marketplace.json must declare a top-level description"),
              at: "marketplace.json (top-level)")
        // By NAME, not `plugins.first`: the moment this manifest lists a second
        // plugin, position stops identifying anything and the guard silently
        // moves to whichever entry happens to be first (#396 verify).
        let pluginName = try XCTUnwrap(pj["name"] as? String)
        let plugins = try XCTUnwrap(mkt["plugins"] as? [[String: Any]])
        let matching = plugins.filter { ($0["name"] as? String) == pluginName }
        XCTAssertEqual(matching.count, 1, "marketplace must have exactly one named plugin entry")
        let entry = try XCTUnwrap(matching.first,
            "marketplace.json lists no entry named '\(pluginName)'")
        check(try XCTUnwrap(entry["description"] as? String, "marketplace entry must declare a description"),
              at: "marketplace.json (entry)")

        // Not `== 3`, which would be true however few surfaces existed: assert
        // each named surface was reached.
        XCTAssertEqual(inspected, 3,
            "expected plugin.json + marketplace top-level + marketplace entry '\(pluginName)' "
            + "to be inspected; got \(inspected)")
    }

    func testPluginChangelogNewestMatchesPluginVersion() throws {
        // #396 round 2: plugin/CHANGELOG.md is the anointed single shell-narrative
        // source, but a single source with no owner rots (this repo's #311 lesson;
        // at anointing time it was already two minor versions behind). Pin its
        // newest released header to plugin.json's `version` — a shell release that
        // forgets its changelog entry now fails the suite.
        let probe = try ChangelogParserTests.run(
            ["newest"], changelog: repoRoot().appendingPathComponent("plugin/CHANGELOG.md").path)
        guard probe.status == 0, !probe.out.isEmpty else {
            XCTFail("no released ## [x.y.z] header found in plugin/CHANGELOG.md")
            return
        }
        let pjData = try Data(contentsOf: repoRoot().appendingPathComponent("plugin/.claude-plugin/plugin.json"))
        let pj = try XCTUnwrap(try JSONSerialization.jsonObject(with: pjData) as? [String: Any])
        let shellVersion = try XCTUnwrap(pj["version"] as? String)
        XCTAssertEqual(probe.out, shellVersion,
            "plugin/CHANGELOG.md newest released header ('\(probe.out)') must match plugin.json "
            + "version ('\(shellVersion)') — the single narrative source needs an owner (#396); "
            + "write the release entry alongside the version bump.")

        let notes = try ChangelogParserTests.run(
            ["notes", probe.out], changelog: repoRoot().appendingPathComponent("plugin/CHANGELOG.md").path)
        XCTAssertEqual(notes.status, 0)
        let visible = notes.out.replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
        let substantive = visible.split(separator: "\n").filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("```") && !line.hasPrefix("~~~")
        }
        XCTAssertFalse(substantive.isEmpty, "Newest shell release must contain an actual change note")
    }

    func testPluginChangelogIsOrderedAndComplete() throws {
        let probe = try ChangelogParserTests.run(
            ["entries"], changelog: repoRoot().appendingPathComponent("plugin/CHANGELOG.md").path)
        XCTAssertEqual(probe.status, 0)
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(probe.out.utf8)) as? [[String: Any]])
        guard !rows.isEmpty else { XCTFail("Shell changelog has no release entries"); return }
        var entries: [(version: String, parts: [Int], date: String)] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        for row in rows {
            let version = try XCTUnwrap(row["version"] as? String)
            let header = try XCTUnwrap(row["header"] as? String)
            let parts = version.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 3 else { XCTFail("Version components overflow: \(version)"); continue }
            let prefix = "## [\(version)] - "
            guard header.hasPrefix(prefix) else { XCTFail("Missing canonical date in \(header)"); continue }
            let date = String(header.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard let parsed = formatter.date(from: date), formatter.string(from: parsed) == date else {
                XCTFail("Invalid release date: \(date)"); continue
            }
            entries.append((version, parts, date))
        }
        for (a, b) in zip(entries, entries.dropFirst()) {
            XCTAssertTrue(b.parts.lexicographicallyPrecedes(a.parts),
                          "Shell release versions must descend without duplicates: \(a.version), \(b.version)")
        }
        // Frozen audit data covers every observed manifest version in the
        // stated historical interval. Do not assume that every possible minor
        // was published, or that a future backport must have an older date.
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("Tests/Fixtures/plugin-release-history.json"))
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expected = try XCTUnwrap(fixture["records"] as? [[String: Any]])
        XCTAssertFalse(expected.isEmpty)
        for record in expected {
            let version = try XCTUnwrap(record["version"] as? String)
            let date = try XCTUnwrap(record["date"] as? String)
            let matches = entries.filter { $0.version == version }
            XCTAssertEqual(matches.count, 1, "Historical release \(version) missing or duplicated")
            XCTAssertEqual(matches.first?.date, date, "Historical date drift for \(version); recheck its source commit")
        }
    }

    func testBinaryPinNamesAShippedBinary() throws {
        // #396 verify: `binary_version` is the field that decides which binary
        // users actually download, and NOTHING owned it. This PR deletes the
        // surfaces that used to cross-check it by eye (README's "shell vX +
        // binary vY" pairs, and the description narrative), so without a
        // mechanical check the redundancy is removed and nothing replaces it.
        //
        // The repo has already paid for this once — plugin/CHANGELOG [2.44.1]
        // records v2.44.0 shipping an SOP documented against binary v2.26.0+
        // while plugin.json still pinned 2.25.0 and marketplace.json 2.24.0.
        // Users ran a binary without the fix; 24 self-sent messages were
        // mislabelled. The failure was silent.
        //
        // A pin can never legitimately name a binary that was never released,
        // so check its documented release in the ROOT changelog using the shared parser.
        // A changelog entry alone does not prove that a GitHub asset was published.
        let pjData = try Data(contentsOf: repoRoot().appendingPathComponent("plugin/.claude-plugin/plugin.json"))
        let pj = try XCTUnwrap(try JSONSerialization.jsonObject(with: pjData) as? [String: Any])
        let binaryPin = try XCTUnwrap(pj["binary_version"] as? String,
            "plugin.json must declare binary_version — the wrapper downloads whatever it names")

        let result = try ChangelogParserTests.run(["has", binaryPin])
        XCTAssertEqual(result.status, 0,
            "binary_version \(binaryPin) must have a real, unfenced root changelog section. "
            + "This is a documentation check; release availability is verified separately.")
    }
}
