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
/// `git rm --cached`; this test pins the INDEX so neither direction regresses:
/// no build artifact sneaks back in (`git add -f`), and no release-critical
/// file (manifest.json etc.) quietly leaves. Changing the tracked set under
/// `mcpb/` is a conscious act: update `expected` here in the same commit.
///
/// Verify-round hardening (#397 round 1): errors are NOT skips — only a source
/// tree that genuinely is not a git checkout may skip; every other git failure
/// fails the test with git's own stderr, because an error-shaped skip is how a
/// guard rots green in CI. Pipe reads happen before `waitUntilExit()` (same
/// ordering as `ChangelogParserTests`) so a pipe-buffer-filling `ls-files`
/// listing — the very regression this guard hunts — fails loudly instead of
/// deadlocking the suite.
final class NoTrackedBuildArtifactsTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
    }

    private func runGit(_ args: [String], at dir: URL) throws -> (status: Int32, out: String, err: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git"] + args
        proc.currentDirectoryURL = dir
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        // Read BEFORE waitUntilExit — a child that fills the pipe buffer must
        // surface as output, not deadlock parent-waits-child-waits-parent.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "<non-utf8 stdout>",
                String(data: errData, encoding: .utf8) ?? "<non-utf8 stderr>")
    }

    func testExactTrackedSetUnderMcpb() throws {
        let root = repoRoot()

        // Legitimate skip #1: the compile-time #filePath does not point at a
        // source checkout at all (relocated test bundle, remapped paths).
        guard FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Package.swift").path) else {
            throw XCTSkip("#filePath root has no Package.swift — not a source checkout, index guard not applicable")
        }

        let probe = try runGit(["rev-parse", "--show-toplevel"], at: root)
        if probe.status != 0 {
            let stderr = probe.err.trimmingCharacters(in: .whitespacesAndNewlines)
            // Legitimate skip #2: a source archive with no git metadata.
            if stderr.contains("not a git repository") {
                throw XCTSkip("source tree is not a git checkout — index guard not applicable (\(stderr))")
            }
            // Everything else (permissions, safe.directory, corruption, env
            // pollution) FAILS: an unreadable index is not a clean one.
            XCTFail("git rev-parse failed (status \(probe.status)) — refusing to skip on an error: \(stderr)")
            return
        }

        // Upper-repo guard: a checkout nested inside some other repository must
        // not audit the ENCLOSING repo's index (false pass or false fail either
        // way). Worktrees are fine: --show-toplevel returns the worktree root.
        let toplevel = URL(fileURLWithPath: probe.out.trimmingCharacters(in: .whitespacesAndNewlines))
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootResolved = root.standardizedFileURL.resolvingSymlinksInPath()
        guard toplevel.path == rootResolved.path else {
            throw XCTSkip("git toplevel (\(toplevel.path)) is not the package root (\(rootResolved.path)) — refusing to audit an enclosing repository")
        }

        let ls = try runGit(["ls-files", "mcpb"], at: root)
        guard ls.status == 0 else {
            XCTFail("git ls-files failed (status \(ls.status)): \(ls.err.trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }

        let tracked = Set(ls.out.split(separator: "\n").map(String.init))
        let expected: Set<String> = [
            "mcpb/PRIVACY.md",
            "mcpb/icon.png",
            "mcpb/manifest.json",
            "mcpb/server/.gitkeep",
        ]

        // Exact set, both directions (#397 round 1): subtractive-only checking
        // let `git rm --cached mcpb/manifest.json` pass while the failure
        // message claimed to protect it.
        let unexpected = tracked.subtracting(expected).sorted()
        let missing = expected.subtracting(tracked).sorted()
        XCTAssertTrue(unexpected.isEmpty,
            "unexpected tracked file(s) under mcpb/: \(unexpected) — build artifacts must stay "
            + "untracked (#391: a tracked bundle/binary freezes at commit time, then ships stale "
            + "to every marketplace clone). A legitimately new tracked file requires extending "
            + "`expected` in this test, in the same commit.")
        XCTAssertTrue(missing.isEmpty,
            "release-critical file(s) MISSING from the index: \(missing) — scripts/release.sh and "
            + "scripts/package-mcpb.sh read mcpb/manifest.json from a fresh clone; icon/PRIVACY "
            + "ship inside the .mcpb. Restore them or consciously update `expected`.")
    }
}
