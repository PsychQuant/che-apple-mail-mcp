import XCTest
@testable import CheAppleMailMCP

/// #303 — `AppVersion.current` is the server's self-reported version and the
/// baseline for staleness detection. These tests + `scripts/release.sh`'s
/// die-on-drift guard together make the `2.7.2`-rot failure structurally
/// impossible to repeat: the version cannot silently disagree with the release.
final class VersionTests: XCTestCase {

    func testCurrentIsValidSemver() {
        XCTAssertNotNil(SemVer(AppVersion.current),
                        "AppVersion.current must be a valid major.minor.patch: got '\(AppVersion.current)'")
        XCTAssertFalse(AppVersion.current.isEmpty)
        XCTAssertNotEqual(AppVersion.current, "0.0.0", "must be a real version, not a placeholder")
    }

    /// Locks `AppVersion.current` to the newest released `## [x.y.z]` header in
    /// CHANGELOG.md — CI catches version/CHANGELOG drift between releases, the
    /// same invariant `release.sh` enforces at tag time.
    func testCurrentMatchesNewestChangelogEntry() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
        let changelog = repoRoot.appendingPathComponent("CHANGELOG.md")
        let text = try String(contentsOf: changelog, encoding: .utf8)

        // #349: ask `scripts/changelog.py` — the repo's single definition of a
        // released header — instead of re-parsing. This local scan went through
        // `SemVer()`, which discards a `-suffix` by design, so `## [2.27.0-rc1]`
        // was accepted here while `ManifestVersionTests` skipped it: the two
        // guards #303/#311 set against each other could measure different
        // headers and both stay green.
        let probe = try ChangelogParserTests.run(["newest"], changelog: changelog.path)
        XCTAssertEqual(probe.status, 0, "scripts/changelog.py could not read CHANGELOG.md")
        let newestVersion = probe.out
        XCTAssertFalse(newestVersion.isEmpty, "no released `## [x.y.z]` header in CHANGELOG.md")
        _ = text
        XCTAssertEqual(AppVersion.current, newestVersion,
                       "AppVersion.current ('\(AppVersion.current)') must match the newest CHANGELOG release "
                       + "('\(newestVersion)') — bump both together (release.sh enforces this at tag time).")
    }
}
