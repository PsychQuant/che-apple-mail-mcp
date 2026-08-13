import XCTest

/// #349-A — one definition of "a released CHANGELOG header", shared by every
/// consumer.
///
/// `VersionTests`, `ManifestVersionTests` and `scripts/release.sh` each located
/// "the newest released `## [x.y.z]`" with their own logic, and they could
/// disagree. That matters because #303 and #311 deliberately set two of those
/// guards against each other as belt-and-braces — and belt-and-braces is only
/// as strong as the two agreeing on what they measure. Measured divergences:
///
/// - `## [2.27.0-rc1]` — `VersionTests` accepted it (`SemVer()` discards a
///   `-suffix` by design), `ManifestVersionTests` required three integer
///   components and skipped past it. `AppVersion.current` and the manifest
///   version could therefore hold DIFFERENT values with CI fully green.
/// - `## [9.9.9]` inside a fenced code block was a real release header to all
///   three.
///
/// `scripts/changelog.py` is now that single definition; this pins its
/// behaviour, and the two version guards call it instead of re-parsing.
final class ChangelogParserTests: XCTestCase {

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Run `scripts/changelog.py` and return (exit status, stdout).
    @discardableResult
    static func run(_ args: [String], changelog: String? = nil) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", repoRoot.appendingPathComponent("scripts/changelog.py").path]
            + args + [changelog ?? repoRoot.appendingPathComponent("CHANGELOG.md").path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    private func fixture(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("changelog-\(UUID().uuidString).md")
        try body.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    // MARK: - the two measured divergences

    func testPrereleaseHeaderIsNotAReleasedVersion() throws {
        let path = try fixture("""
        # Changelog

        ## [Unreleased]

        ## [2.27.0-rc1] - 2026-08-12
        prerelease

        ## [2.27.0] - 2026-08-10
        real
        """)
        XCTAssertEqual(try Self.run(["newest"], changelog: path).out, "2.27.0",
            "a -rc suffix is not a release; release.sh's tag validator refuses such a tag, "
            + "so accepting one here would let a prerelease become what AppVersion.current "
            + "is measured against")
        XCTAssertNotEqual(try Self.run(["has", "2.27.0-rc1"], changelog: path).status, 0)
        XCTAssertEqual(try Self.run(["has", "2.27.0"], changelog: path).status, 0)
    }

    func testHeaderInsideAFencedBlockIsNotAReleasedVersion() throws {
        let path = try fixture("""
        # Changelog

        Example of the format:

        ```markdown
        ## [9.9.9] - 2099-01-01
        not real
        ```

        ## [2.27.0] - 2026-08-10
        real
        """)
        XCTAssertEqual(try Self.run(["newest"], changelog: path).out, "2.27.0")
        XCTAssertNotEqual(try Self.run(["has", "9.9.9"], changelog: path).status, 0)
    }

    func testTildeFenceIsHonouredAndBacktickInsideItDoesNotCloseIt() throws {
        let path = try fixture("""
        # Changelog

        ~~~
        ```
        ## [9.9.9] - 2099-01-01
        ~~~

        ## [2.27.0] - 2026-08-10
        real
        """)
        XCTAssertEqual(try Self.run(["newest"], changelog: path).out, "2.27.0")
    }

    // MARK: - ordinary behaviour

    func testNotesReturnsOnlyThatSectionsBody() throws {
        let path = try fixture("""
        ## [Unreleased]

        pending

        ## [2.27.0] - 2026-08-10

        line one
        line two

        ## [2.26.0] - 2026-08-01

        older
        """)
        XCTAssertEqual(try Self.run(["notes", "2.27.0"], changelog: path).out, "line one\nline two")
    }

    func testUnreleasedIsNeverTheNewestRelease() throws {
        let path = try fixture("""
        ## [Unreleased]

        pending

        ## [2.27.0] - 2026-08-10
        real
        """)
        XCTAssertEqual(try Self.run(["newest"], changelog: path).out, "2.27.0")
    }

    func testMissingVersionAndEmptyFileFailRatherThanReturnEmpty() throws {
        let empty = try fixture("# Changelog\n\nnothing here\n")
        XCTAssertNotEqual(try Self.run(["newest"], changelog: empty).status, 0)
        XCTAssertNotEqual(try Self.run(["notes", "1.0.0"], changelog: empty).status, 0)
    }

    func testTheRealChangelogParses() throws {
        let r = try Self.run(["newest"])
        XCTAssertEqual(r.status, 0)
        XCTAssertFalse(r.out.isEmpty, "the repo's own CHANGELOG must yield a released version")
    }
}
