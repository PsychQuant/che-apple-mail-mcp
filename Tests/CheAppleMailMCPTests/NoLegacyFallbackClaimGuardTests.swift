import XCTest
@testable import CheAppleMailMCP

/// #475 verify R4 + #486 — #304 deleted the legacy (AppleScript body-injection)
/// compose path, so no text may claim that compose still falls back to it.
///
/// Round 3 of #475 swept tool descriptions but missed the text
/// `check_accessibility` actually RETURNS; round 5 then found the fix itself had
/// over-corrected into "nothing falls back", which is untrue for the opt-in
/// direct-write `create_draft` (a reversed direct write takes the GUI path), and
/// that a phrase blocklist let reworded claims through. So this guard checks
/// properties, not phrasings:
///
/// 1. Runtime text a caller or user reads: a "no fallback" statement must be
///    scoped to the legacy path, and any mention of direct write must state that
///    it applies only to calls meeting its conditions.
/// 2. Sources: any line that mentions the legacy compose fallback must cite
///    #304 on the same line, marking it as removed. Account-reference "legacy"
///    forms (`account "<display_name>"`) are a different, still-true statement;
///    a match whose line or next line names display_name / `account is skipped.
/// 3. Docs: the `[legacy path — …]` disclosure marker #304 removed must not be
///    described as current.
final class NoLegacyFallbackClaimGuardTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every piece of text a caller or user reads about the Accessibility grant,
    /// with whitespace folded to single spaces so a hard line wrap (guidance()
    /// is a multi-line literal) cannot turn a phrase check into a no-op.
    private static var runtimeTexts: [(String, String)] {
        rawRuntimeTexts.map { ($0.0, $0.1.split(whereSeparator: \.isWhitespace).joined(separator: " ")) }
    }

    private static var rawRuntimeTexts: [(String, String)] {
        let description = CheAppleMailMCPServer.defineTools()
            .first { $0.name == "check_accessibility" }?.description ?? ""
        return [
            ("summary(.granted) + grantedDetail",
             AccessibilityStatus.summary(.granted) + "\n" + AccessibilityStatus.grantedDetail),
            ("summary(.denied)", AccessibilityStatus.summary(.denied)),
            ("guidance()", AccessibilityStatus.guidance()),
            ("setupNote", AccessibilityStatus.setupNote),
            ("check_accessibility description", description),
        ]
    }

    func testRuntimeTextMakesNoLegacyClaim() {
        let stale = ["falls back to the legacy path", "still work", "body is wrapped",
                     "compose falls back", "legacy AppleScript injection —"]
        for (name, text) in Self.runtimeTexts {
            XCTAssertFalse(text.isEmpty, "\(name) is empty")
            for claim in stale {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(claim), "\(name): stale claim \"\(claim)\"")
            }
        }
    }

    func testNoFallbackStatementsAreScopedToTheLegacyPath() throws {
        // A bare "no fallback" is untrue for create_draft: a direct write that is
        // ineligible or reversed continues on the GUI path, by design (#475).
        let unscoped = try NSRegularExpression(
            pattern: #"nothing falls back|no fallback(?! to the (removed )?legacy)|falls back to another path"#,
            options: [.caseInsensitive])
        for (name, text) in Self.runtimeTexts {
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertNil(unscoped.firstMatch(in: text, range: range),
                         "\(name): a no-fallback statement must say it is the legacy path that is gone: \(text)")
        }
    }

    func testDirectWriteMentionsStateTheyAreConditional() {
        for (name, text) in Self.runtimeTexts where text.contains("direct-write") || text.contains("DIRECT_DRAFT") {
            XCTAssertTrue(text.localizedCaseInsensitiveContains("only when"),
                          "\(name): direct write applies only to calls meeting its conditions; say so: \(text)")
        }
    }

    func testDeniedTextKeepsTheFailureAndTheExceptions() {
        let denied = AccessibilityStatus.summary(.denied)
        XCTAssertTrue(denied.contains("fail"), "the denied summary must say the GUI compose paths fail")
        XCTAssertTrue(denied.contains("forward_email-with-a-body"), "a bare forward needs no grant")
        XCTAssertTrue(AccessibilityStatus.guidance().contains("CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT"),
                      "the guidance must name the direct-write exception")
    }

    func testSourceMentionsOfTheLegacyComposeFallbackCiteItsRemoval() throws {
        let sources = Self.repoRoot.appendingPathComponent("Sources/CheAppleMailMCP")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        let legacyCompose = try NSRegularExpression(
            pattern: #"legacy (injection|fallback|re-send|native-attach|`set sender`)|legacy-wrap|(fall|falls|routed|gated|over-reject) (back )?to (the )?legacy|to the legacy path"#,
            options: [.caseInsensitive])
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where !line.contains("#304") {
                let range = NSRange(line.startIndex..., in: line)
                // The account-reference "legacy" form (`account "<display_name>"`)
                // is still true. Skip only when this line names it, or when the
                // sentence wraps and the next line starts with the `account form.
                let next = index + 1 < lines.count ? lines[index + 1] : ""
                let nextBody = next.trimmingCharacters(in: .whitespaces)
                    .drop { $0 == "/" }.trimmingCharacters(in: .whitespaces)
                if line.contains("display_name") || line.contains("`account") || nextBody.hasPrefix("`account") { continue }
                if legacyCompose.firstMatch(in: line, range: range) != nil {
                    offenders.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "mentions of the legacy compose fallback must cite #304 (it was removed):\n"
                      + offenders.joined(separator: "\n"))
    }

    /// AppleScript `error "…"` inside a Swift triple-quoted script, or
    /// `error \"…\"` inside a single-line Swift string: an optional backslash
    /// before each quote, then everything up to the next quote.
    private static let appleScriptErrorPattern = #"error \\?"[^"]*""#
    private static let stringLiteralPattern = #""([^"\\\n]|\\.)*""#
    private static let fallbackClaimPattern = #"fall(s|ing)? ?back|fallback"#

    /// #486 verify round 2: the first version of the AppleScript-error pattern
    /// was written `\?` (a literal question mark) instead of `\\?`, so it matched
    /// nothing and the repo-wide half of the scan below passed vacuously. Pin the
    /// patterns against known inputs so a dead pattern fails here.
    func testScanPatternsMatchWhatTheyClaimTo() throws {
        let appleScriptError = try NSRegularExpression(pattern: Self.appleScriptErrorPattern)
        let claim = try NSRegularExpression(pattern: Self.fallbackClaimPattern, options: [.caseInsensitive])
        func matches(_ regex: NSRegularExpression, _ text: String) -> [String] {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { (text as NSString).substring(with: $0.range) }
        }
        XCTAssertEqual(matches(appleScriptError, #"    if x then error "no window (falling back)""#),
                       [#"error "no window (falling back)""#], "unescaped AppleScript error literal")
        XCTAssertEqual(matches(appleScriptError, #"let s = "if x then error \"stop (safe fallback)\" end if""#),
                       [#"error \"stop (safe fallback)\""#], "escaped form inside a single-line Swift string")
        // The dead first version, kept as a counter-example: it matches nothing real.
        let deadVersion = try NSRegularExpression(pattern: #"error \?"([^"\\]|\\.)*\?""#)
        XCTAssertTrue(matches(deadVersion, #"    if x then error "no window (falling back)""#).isEmpty)
        for text in ["falling back", "safe fallback", "falls back", "fall back"] {
            XCTAssertFalse(matches(claim, text).isEmpty, "claim pattern must flag \"\(text)\"")
        }
        XCTAssertTrue(matches(claim, "stopping before the next keystroke (nothing sent)").isEmpty)
    }

    /// #486 verify: the reply/forward front guard threw "… — falling back" and
    /// the window checks threw "(safe fallback)". Those AppleScript errors reach
    /// the caller verbatim (mapRuntimeError returns them unchanged), so a caller
    /// was told a fallback happened when the call had failed.
    ///
    /// Scope, stated exactly: AppleScript `error "…"` literals in every source
    /// file, plus every string literal in the two compose builders. Swift-side
    /// MailError text in other files is NOT scanned — read tools there have real
    /// SQLite → AppleScript fallbacks whose messages say so legitimately.
    func testComposeErrorTextDoesNotClaimAFallback() throws {
        let sources = Self.repoRoot.appendingPathComponent("Sources/CheAppleMailMCP")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let composeBuilders: Set<String> = ["ComposeScriptBuilder.swift", "MailtoCompose.swift"]
        let appleScriptError = try NSRegularExpression(pattern: Self.appleScriptErrorPattern)
        let stringLiteral = try NSRegularExpression(pattern: Self.stringLiteralPattern)
        let claim = try NSRegularExpression(pattern: Self.fallbackClaimPattern, options: [.caseInsensitive])
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                let pattern = composeBuilders.contains(file.lastPathComponent) ? stringLiteral : appleScriptError
                let range = NSRange(line.startIndex..., in: line)
                for match in pattern.matches(in: line, range: range) {
                    let literal = (line as NSString).substring(with: match.range)
                    if claim.firstMatch(in: literal, range: NSRange(literal.startIndex..., in: literal)) != nil {
                        offenders.append("\(file.lastPathComponent):\(index + 1): \(literal)")
                    }
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "compose error text must not claim a fallback (the call fails; #304):\n"
                      + offenders.joined(separator: "\n"))
    }

    func testDocsDoNotDescribeTheRemovedDisclosureMarker() throws {
        let docs = ["README.md", "README_zh-TW.md", "plugin/CLAUDE.md", "plugin/README.md",
                    "openspec/specs/draft-update/spec.md"]
        for doc in docs {
            let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(doc), encoding: .utf8)
            XCTAssertFalse(text.contains("`[legacy path"), "\(doc) still describes the removed [legacy path — …] marker")
            XCTAssertFalse(text.contains("legacy-path disclosure"), "\(doc) still promises a legacy-path disclosure")
        }
    }
}
