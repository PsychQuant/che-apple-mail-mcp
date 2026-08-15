import XCTest

/// #304 — no composing path may assign an outgoing message's body via AppleScript.
///
/// Mail wraps ANY AppleScript-assigned body in `<blockquote type="cite">` at MIME
/// serialization (#175, runtime-confirmed, not strippable afterwards). The wrapper
/// is invisible to the sender — its inline style has no border, so Apple Mail
/// renders it normally — while Gmail's web UI and Outlook show the whole letter as
/// quoted text.
///
/// On 2026-07-29 an outbound formal meeting notice to 10 recipients went out that
/// way. It could not be recalled. The trigger was a cc carrying a Chinese display
/// name — a choice with no visible relationship to body rendering.
///
/// The fix for that incident is not a stricter default. `require_wrapper_free`
/// already existed and already defaulted to false; a default can be flipped back,
/// forgotten, or bypassed by the next ineligibility dimension nobody thought of.
/// This guard enforces the structural version instead: **the code that produces a
/// wrapper does not exist**, so no future caller can reach it.
///
/// Scanned over WHOLE file text rather than line by line, and deliberately
/// comment-agnostic — both for the reasons `NoNonThrowingStderrWriteGuardTests`
/// documents: a call split across lines walks straight through a line-based
/// matcher, and a guard defeated by appending a comment is not a guard. The cost
/// is that prose must not spell the banned forms; this file names them only inside
/// the regex literals below.
final class NoBodyInjectionGuardTests: XCTestCase {

    private func shippedSourcesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <package root>/
            .appendingPathComponent("Sources")
    }

    func testNoSourceFileAssignsAMessageBodyViaAppleScript() throws {
        // Three forms, because the incident's inventory found all three in use:
        //   `set content to …`         — plain body assignment
        //   `set html content to …`    — rich body assignment
        //   `content:"…"` inside `make new outgoing message with properties {…}`
        // The third is the one a "grep for set content" sweep misses.
        let setContent = try NSRegularExpression(
            pattern: #"set\s+(html\s+)?content\s+to"#)
        let makeProperties = try NSRegularExpression(
            pattern: #"make\s+new\s+outgoing\s+message[\s\S]{0,200}?\bcontent\s*:"#)

        var offenders: [String] = []
        for url in try swiftFiles() {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let range = NSRange(text.startIndex..., in: text)
            for m in setContent.matches(in: text, range: range) {
                offenders.append("\(url.lastPathComponent):\(line(of: m.range, in: text)): "
                                 + "AppleScript body assignment")
            }
            for m in makeProperties.matches(in: text, range: range) {
                offenders.append("\(url.lastPathComponent):\(line(of: m.range, in: text)): "
                                 + "body supplied in outgoing-message construction")
            }
        }

        XCTAssertTrue(offenders.isEmpty,
            "Mail wraps any AppleScript-assigned body in <blockquote type=\"cite\">, which the "
            + "sender cannot see locally and which sent a formal letter out as quoted text "
            + "(#304). Bodies must come from Mail's own editor — the mailto hand-off, or the "
            + "native reply/forward verb plus paste:\n" + offenders.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private func swiftFiles() throws -> [URL] {
        let root = shippedSourcesDir()
        guard let e = FileManager.default.enumerator(at: root,
                                                     includingPropertiesForKeys: nil) else {
            return []
        }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func line(of range: NSRange, in text: String) -> Int {
        guard let r = Range(range, in: text) else { return 0 }
        return text[text.startIndex..<r.lowerBound].filter { $0 == "\n" }.count + 1
    }
}
