import XCTest

/// #391 — two v2.7.1-era build artifacts (`mcpb/che-apple-mail-mcp.mcpb`, 4.6 MB;
/// `mcpb/server/CheAppleMailMCP`, 18 MB) were committed before `.gitignore` grew
/// its mcpb rules, froze ~21 releases behind, and — once #335 made this repo a
/// self-hosted marketplace — started shipping to every plugin user's disk on
/// `marketplace add` as a double-click install trap: the bundle's inner manifest
/// said 2.7.1 while the sibling `mcpb/manifest.json` said the current release,
/// and the binary was ad-hoc signed, which macOS 26 TCC kills outright.
///
/// `.gitignore` cannot untrack an already-tracked file, so the fix is
/// `git rm --cached`; this test pins the INDEX with a whitelist so a future
/// `git add -f` (or a new large artifact) cannot silently regress it. Adding a
/// legitimate new tracked file under `mcpb/` is a conscious act: extend the
/// whitelist here in the same commit.
final class NoTrackedBuildArtifactsTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
    }

    func testOnlyWhitelistedFilesTrackedUnderMcpb() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git", "ls-files", "mcpb"]
        proc.currentDirectoryURL = repoRoot()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            throw XCTSkip("git unavailable — index guard skipped (not silently passed)")
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw XCTSkip("git ls-files failed (status \(proc.terminationStatus)) — index guard skipped")
        }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let tracked = out.split(separator: "\n").map(String.init)
        XCTAssertFalse(tracked.isEmpty, "git ls-files mcpb returned nothing — mcpb/manifest.json should be tracked")

        let allowed: Set<String> = [
            "mcpb/PRIVACY.md",
            "mcpb/icon.png",
            "mcpb/manifest.json",
            "mcpb/server/.gitkeep",
        ]
        let offenders = tracked.filter { !allowed.contains($0) }
        XCTAssertTrue(offenders.isEmpty,
            "unexpected tracked file(s) under mcpb/: \(offenders) — build artifacts must stay "
            + "untracked (#391: a tracked .mcpb/server binary freezes at commit time, then ships "
            + "stale to every marketplace clone). If a new file is legitimately tracked, extend "
            + "this whitelist in the same commit.")
    }
}
