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
}
