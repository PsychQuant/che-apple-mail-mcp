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
        let entry = try XCTUnwrap(plugins.first, "marketplace.json must list the plugin entry")
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
        // #396: the 18.8KB description-as-changelog convention is dead — the
        // narrative lives in CHANGELOG.md, and a description that names versions
        // starts lying the release after it was written (observed: "Shell v2.43.0
        // ... binary stays v2.25.0" shipping beside version 2.46.1 / pin 2.28.0).
        // Guard both manifests that carry a description.
        let root = repoRoot()
        for rel in ["plugin/.claude-plugin/plugin.json", ".claude-plugin/marketplace.json"] {
            let data = try Data(contentsOf: root.appendingPathComponent(rel))
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let descriptions: [String]
            if let plugins = obj["plugins"] as? [[String: Any]] {
                descriptions = plugins.compactMap { $0["description"] as? String }
            } else {
                descriptions = [obj["description"] as? String].compactMap { $0 }
            }
            for desc in descriptions {
                XCTAssertLessThan(desc.count, 1000,
                    "\(rel): description is \(desc.count) chars — the changelog-in-a-field "
                    + "convention is dead (#396); narrative belongs in CHANGELOG.md")
                for banned in ["Shell v", "binary stays", "ships binary"] {
                    XCTAssertFalse(desc.contains(banned),
                        "\(rel): description contains version-narrative marker '\(banned)' (#396)")
                }
            }
        }
    }
}
