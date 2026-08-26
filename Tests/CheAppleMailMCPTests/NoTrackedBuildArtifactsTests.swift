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
/// Verify-round hardening (#397): errors are NOT skips. There are exactly two
/// skip paths, and **both are decided on filesystem evidence, never on git's
/// prose**: no `Package.swift` at the `#filePath` root, or no `.git` there.
/// Round 1 keyed the second skip on the string "not a git repository", which
/// round 2 showed is emitted verbatim for `GIT_DIR=/nonexistent` against a tree
/// that IS a checkout (verified), and is localized under a non-English locale —
/// an error-shaped skip is how a guard rots green.
///
/// The child git is `/usr/bin/git` with a `GIT_*`-scrubbed environment: a PATH
/// shim must not decide the verdict, an inherited `GIT_INDEX_FILE` must not
/// point `ls-files` at a substituted index while `rev-parse` still reports the
/// real root. Both output streams go to temp files rather than pipes, which
/// removes the two-pipe deadlock class outright (draining stdout to EOF first
/// hangs forever when the child blocks on a full stderr buffer).
final class NoTrackedBuildArtifactsTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
    }

    private func runGit(_ args: [String], at dir: URL) throws -> (status: Int32, out: String, err: String) {
        let proc = Process()
        // Absolute path, not `/usr/bin/env git`: PATH decides which binary a
        // shim resolves to, and this guard's verdict must not be PATH-settable.
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = dir
        // Scrub GIT_*: an inherited GIT_INDEX_FILE aims `ls-files` at a
        // substituted index while `rev-parse --show-toplevel` still returns the
        // real root, so the upper-repo check passes and the guard audits an
        // index that is not this repository's. LC_ALL=C keeps failure messages
        // stable (no decision depends on the wording any more, but readers do).
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["LC_ALL"] = "C"
        proc.environment = env

        // Temp files, not pipes: reading two pipes sequentially deadlocks when
        // the child blocks writing a full stderr buffer (64 KB on Darwin) —
        // it can never exit, so stdout never EOFs, so the stderr read is never
        // reached. A regular file has no such limit. The per-user Darwin temp
        // dir plus a UUID leaves no predictable name to pre-symlink.
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("che-mail-git-out-\(UUID().uuidString)")
        let errURL = tmp.appendingPathComponent("che-mail-git-err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        proc.standardOutput = outHandle
        proc.standardError = errHandle
        try proc.run()
        proc.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()

        let outData = (try? Data(contentsOf: outURL)) ?? Data()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
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

        // Whether this tree carries git metadata is a filesystem fact, and it is
        // the ONLY thing the skip decisions below are allowed to rest on. (A
        // worktree's `.git` is a file, not a directory — `fileExists` covers
        // both.)
        let dotGit = root.appendingPathComponent(".git")
        let hasGitMetadata = FileManager.default.fileExists(atPath: dotGit.path)

        let probe = try runGit(["rev-parse", "--show-toplevel"], at: root)
        if probe.status != 0 {
            let stderr = probe.err.trimmingCharacters(in: .whitespacesAndNewlines)
            // Legitimate skip #2: a source archive with no git metadata at all.
            guard !hasGitMetadata else {
                // .git IS there and git still refused: permissions,
                // safe.directory, corruption, or a polluted environment we
                // failed to scrub. An unreadable index is not a clean one.
                XCTFail("git rev-parse failed (status \(probe.status)) although \(dotGit.path) exists "
                    + "— refusing to skip on an error: \(stderr)")
                return
            }
            throw XCTSkip("no .git at the package root — not a git checkout, index guard not applicable (\(stderr))")
        }

        // Upper-repo guard: a checkout nested inside some other repository must
        // not audit the ENCLOSING repo's index (false pass or false fail either
        // way). Worktrees are fine: --show-toplevel returns the worktree root.
        let toplevel = URL(fileURLWithPath: probe.out.trimmingCharacters(in: .whitespacesAndNewlines))
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootResolved = root.standardizedFileURL.resolvingSymlinksInPath()
        guard toplevel.path == rootResolved.path else {
            // Same rule as above: skip only when the filesystem says this tree
            // owns no repository of its own (a vendored copy inside someone
            // else's checkout). If `.git` IS here, a mismatch is not a benign
            // nesting — something is aiming git elsewhere, and that is a
            // failure, not a green run.
            guard !hasGitMetadata else {
                XCTFail("git toplevel (\(toplevel.path)) is not the package root (\(rootResolved.path)) "
                    + "although .git exists there — the index this would audit is not this package's")
                return
            }
            throw XCTSkip("no .git at the package root and git resolved an enclosing repository "
                + "(\(toplevel.path)) — refusing to audit it")
        }

        // -z: NUL-delimited and unquoted, so a path with a newline or a
        // non-ASCII byte cannot be mangled by core.quotePath into a name that
        // silently fails to match `expected`.
        let ls = try runGit(["ls-files", "-z", "mcpb"], at: root)
        guard ls.status == 0 else {
            XCTFail("git ls-files failed (status \(ls.status)): \(ls.err.trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }

        let tracked = Set(ls.out.split(separator: "\0").map(String.init).filter { !$0.isEmpty })
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
