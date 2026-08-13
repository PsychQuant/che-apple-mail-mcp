import XCTest

/// #323 — `build-mcpb.sh` and `release.sh` were two unrelated pipelines.
///
/// The release pipeline builds universal, Developer ID signs and notarizes,
/// because on macOS 26 an ad-hoc binary cannot even trigger a TCC dialog
/// (#211) — it structurally cannot acquire Full Disk Access. `build-mcpb.sh`
/// did `swift build -c release` + `cp` + `zip`. Measured on this machine:
/// **arm64-only**, `flags=0x20002(adhoc,linker-signed)`, `TeamIdentifier=not
/// set`. So every Desktop user installing the `.mcpb` got a server that could
/// never be granted the permissions it needs, while the GitHub-release asset
/// beside it was universal and notarized — and the gap widened each release.
///
/// These guards pin the structure of the fix, so the orphan pipeline cannot
/// quietly reappear.
final class McpbPipelineGuardTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func script(_ name: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent("scripts/\(name)"),
                   encoding: .utf8)
    }

    func testThereIsExactlyOnePackagingImplementation() throws {
        let build = try script("build-mcpb.sh")
        XCTAssertTrue(build.contains("package-mcpb.sh"),
            "build-mcpb.sh must delegate to the shared packager, not re-implement zipping")
        XCTAssertFalse(build.contains("zip -r che-apple-mail-mcp.mcpb"),
            "the orphan zip is what shipped an ad-hoc bundle for ~18 releases")
    }

    func testDevPathMustDeclareItselfUndistributable() throws {
        XCTAssertTrue(try script("build-mcpb.sh").contains("MCPB_ALLOW_UNSIGNED=1"),
            "a dev build must say so explicitly — the packager refuses otherwise, and "
            + "that refusal is the only thing standing between a dev bundle and a user")
    }

    func testReleasePackagesTheSignedBinaryAndUploadsIt() throws {
        let release = try script("release.sh")
        XCTAssertTrue(release.contains("package-mcpb.sh"),
            "the .mcpb must be built from the artifact release.sh just signed")
        XCTAssertTrue(release.contains("MCPB_PATH"),
            "and uploaded, so Desktop users get a current signed bundle")
        // Ordering matters: packaging must read the SIGNED binary, so it has to
        // come after signing rather than before.
        let signIdx = release.range(of: "notarytool")?.lowerBound
        let packIdx = release.range(of: "package-mcpb.sh")?.lowerBound
        if let s = signIdx, let p = packIdx {
            XCTAssertTrue(s < p, "packaging must happen AFTER sign+notarize")
        }
    }

    func testPackagerRefusesUndistributableBinariesByDefault() throws {
        let packager = try script("package-mcpb.sh")
        XCTAssertTrue(packager.contains("exit 1"),
            "the gate must fail CLOSED — an unsigned bundle is not a lesser bundle, "
            + "it is one that cannot work at all")
        XCTAssertTrue(packager.contains("lipo -archs") && packager.contains("TeamIdentifier"),
            "both properties that make a bundle usable must be checked")
    }
}
