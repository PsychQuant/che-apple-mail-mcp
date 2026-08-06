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

        // First `## [x.y.z] - ...` header (skips `## [Unreleased]`, which is not x.y.z).
        var newest: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("## [") else { continue }
            let inside = s.dropFirst(4).prefix(while: { $0 != "]" })
            if SemVer(String(inside)) != nil { newest = String(inside); break }
        }

        let newestVersion = try XCTUnwrap(newest, "no `## [x.y.z]` header found in CHANGELOG.md")
        XCTAssertEqual(AppVersion.current, newestVersion,
                       "AppVersion.current ('\(AppVersion.current)') must match the newest CHANGELOG release "
                       + "('\(newestVersion)') — bump both together (release.sh enforces this at tag time).")
    }
}
