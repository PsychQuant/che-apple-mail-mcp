import XCTest

/// #617: `OsascriptFixtureGuard` is called by hand at each fixture, and #617 exists because four
/// fixtures were missed. This scan makes a missed one a failing test, the way
/// `NoContentContainsScanGuardTests` does for its rule.
///
/// It reads `/usr/bin/osascript` written in a test. It does not see production runners a test calls
/// (`runGuiScript`, `runDraftScanScript`, with scripts that name no application), `osacompile`, which
/// compiles and does not run, or osascript reached some other way, such as through `/bin/sh`.
final class OsascriptFixtureGuardScanTests: XCTestCase {

    /// The files whose osascript runs stay outside the guard on purpose, each with its reason.
    static let unguardedOnPurpose: [String: String] = [
        "MailtoComposeLiveTests.swift": "reads and cleans up real Mail state on purpose; skipped unless CHE_MAIL_LIVE_TEST=1",
        "ReplyPasteLiveTests.swift": "reads and cleans up real Mail state on purpose; skipped unless CHE_MAIL_LIVE_TEST=1",
    ]

    private static let needle = "/usr/bin/osascript"

    /// The sites in `source` that run osascript without checking the text they hand it. A site is the
    /// code from the line naming osascript to the first `.run()` after it, and it passes only in the
    /// shape every fixture has: `arguments = ["-e", x]` and `try OsascriptFixtureGuard.check(x` inside
    /// that stretch. Any other shape is reported, so a new one is rewritten or listed, not guessed at.
    static func unguardedSites(in source: String) -> [String] {
        let lines = DirectWriteSafetyGuardTests.codeLines(of: source)
        return lines.indices.filter { lines[$0].contains(needle) }.compactMap { start in
            let run = lines[start...].firstIndex { $0.contains(".run()") } ?? lines.index(before: lines.endIndex)
            return isGuarded(lines[start...run]) ? nil : lines[start]
        }
    }

    private static func isGuarded(_ site: ArraySlice<String>) -> Bool {
        let text = site.joined(separator: "\n")
        guard text.contains(".run()"),
              let range = text.range(of: #"arguments = \["-e", [A-Za-z_][A-Za-z0-9_]*\]"#, options: .regularExpression)
        else { return false }
        let script = text[range].dropFirst(#"arguments = ["-e", "#.count).dropLast()
        return text.range(of: #"\btry OsascriptFixtureGuard\.check\(\#(script)[,)]"#, options: .regularExpression) != nil
    }

    /// Every test source but this file, whose own counter-examples name osascript.
    private static func testSources() throws -> [(name: String, source: String)] {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        var sources: [(name: String, source: String)] = []
        for case let url as URL in walker
        where url.pathExtension == "swift" && url.lastPathComponent != URL(fileURLWithPath: #filePath).lastPathComponent {
            sources.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return sources
    }

    func testEveryOsascriptRunGoesThroughTheGuard() throws {
        var unguarded: [String: [String]] = [:]
        for file in try Self.testSources() {
            let sites = Self.unguardedSites(in: file.source)
            if !sites.isEmpty { unguarded[file.name] = sites }
        }
        // Equal, not a subset: a listed file that stopped running osascript leaves a stale reason.
        XCTAssertEqual(Set(unguarded.keys), Set(Self.unguardedOnPurpose.keys), """
            An osascript run in Tests/ does not check its text, or a file listed in unguardedOnPurpose no \
            longer has such a run. Call `try OsascriptFixtureGuard.check(x)` on the text passed as \
            `arguments = ["-e", x]`, or list the file with its reason. Found: \(unguarded)
            """)
    }

    func testTheScanReadsTheShapesItClaims() {
        func site(_ guardLine: String, arguments: String = #"process.arguments = ["-e", source]"#, run: String = "try process.run()") -> String {
            """
            func runIt(_ source: String) throws {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                \(guardLine)
                \(arguments)
                \(run)
            }
            """
        }
        XCTAssertEqual(Self.unguardedSites(in: site("try OsascriptFixtureGuard.check(source)")), [])
        XCTAssertEqual(Self.unguardedSites(in: site("try OsascriptFixtureGuard.check(source, foundationBridge: true)")), [])
        let unguarded = [
            site(""),
            site("// try OsascriptFixtureGuard.check(source)"),
            site("try? OsascriptFixtureGuard.check(source)"),
            site("try OsascriptFixtureGuard.check(other)"),
            site("try OsascriptFixtureGuard.check(source2)"),
            site("try OsascriptFixtureGuard.check(source)", arguments: #"process.arguments = ["-"]"#),
            site("try OsascriptFixtureGuard.check(source)", run: ""),
        ]
        for text in unguarded {
            XCTAssertEqual(Self.unguardedSites(in: text).count, 1, text)
        }
        XCTAssertEqual(Self.unguardedSites(in: "// " + Self.needle), [], "a comment is not a run")
    }
}
