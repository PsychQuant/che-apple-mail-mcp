import XCTest

/// `release.sh` must find each architecture's binary where SwiftPM actually put it.
///
/// The script used to lipo `.build/arm64-apple-macosx/release/<bin>` and
/// `.build/x86_64-apple-macosx/release/<bin>`. Those are the native build
/// system's per-triple output paths. From Swift 6.4 the default backend is
/// swiftbuild, which writes BOTH architectures to one directory
/// (`.build/out/Products/Release`), the second build overwriting the first, and
/// never touches the per-triple trees again. They keep whatever the last native
/// build left there.
///
/// The first v3.2.0 attempt (2026-10-04) built fresh 3.2.0 binaries and then
/// lipo'd the v3.1.0 binaries from 2026-09-08 out of those stale trees. The #303
/// slice probe refused to sign it, which is the only reason a "3.2.0" release
/// carrying 3.1.0 code did not ship.
///
/// These guards pin the shape of the fix: ask SwiftPM where each build went,
/// check the arch of what is there, and copy it out before the next build can
/// overwrite it.
final class ReleaseBuildPathGuardTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func releaseScript() throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent("scripts/release.sh"),
                   encoding: .utf8)
    }

    /// Lines that are not comments, so the explanation of the bug can name the
    /// old paths without tripping the guard.
    private func code(_ script: String) -> [String] {
        script.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }

    func testNoHardCodedPerTripleProductPath() throws {
        let hits = code(try releaseScript()).filter { $0.contains("-apple-macosx/release") }
        XCTAssertEqual(hits, [],
            "a hard-coded per-triple path reads a stale binary under the swiftbuild backend")
    }

    func testEachArchIsLocatedThroughShowBinPath() throws {
        let lines = code(try releaseScript())
        XCTAssertTrue(lines.contains { $0.contains("--show-bin-path") },
            "the product directory differs between build systems; SwiftPM must be asked")
    }

    func testEachArchIsCopiedOutBeforeTheNextBuild() throws {
        // swiftbuild puts both arches at the same path, so the arm64 product has to
        // be staged before the x86_64 build replaces it. Pin the order inside the
        // build loop: build, locate, check arch, copy.
        let lines = code(try releaseScript())
        guard let build = lines.firstIndex(where: { $0.contains("swift build -c release --arch \"$arch\"") }) else {
            return XCTFail("expected a per-arch build loop over \"$arch\"")
        }
        let tail = Array(lines[build...])
        let locate = tail.firstIndex { $0.contains("--show-bin-path") }
        let check = tail.firstIndex { $0.contains("lipo -archs") }
        let copy = tail.firstIndex { $0.contains("cp ") && $0.contains("STAGE_DIR") }
        let done = tail.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "done" }
        guard let l = locate, let c = check, let p = copy, let d = done else {
            return XCTFail("build loop must locate, arch-check and stage each product "
                + "(locate=\(String(describing: locate)) check=\(String(describing: check)) "
                + "copy=\(String(describing: copy)) done=\(String(describing: done)))")
        }
        XCTAssertTrue(l < c && c < p && p < d,
            "order inside the loop must be locate → arch check → stage, all before `done`")
    }

    func testLipoReadsTheStagedCopies() throws {
        let lines = code(try releaseScript())
        let create = lines.first { $0.contains("lipo -create") } ?? ""
        XCTAssertTrue(create.contains("ARM64_BINARY") && create.contains("X64_BINARY"),
            "lipo -create must still merge the two per-arch binaries")
        let assigns = lines.filter { $0.hasPrefix("ARM64_BINARY=") || $0.hasPrefix("X64_BINARY=") }
        XCTAssertEqual(assigns.count, 2)
        XCTAssertTrue(assigns.allSatisfy { $0.contains("$STAGE_DIR") },
            "the merged inputs must be the staged copies, not a build-tree path")
    }
}
