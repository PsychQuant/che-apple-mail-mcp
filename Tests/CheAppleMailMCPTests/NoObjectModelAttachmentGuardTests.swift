import XCTest

/// #534 — no shipped source may attach a file through Mail's scripting object
/// model.
///
/// The reply path pasted the new body through Mail's editor and then told the
/// reply message to insert an attachment after its last paragraph. That
/// insertion writes the message's `content`, which holds neither the pasted body
/// nor the quote Mail's `reply` verb built, so the saved draft kept only the
/// attachment and the signature while the call reported success (four recorded
/// drafts, #534 and #461). It is a fourth form of writing `content` from
/// AppleScript, next to the three `NoBodyInjectionGuardTests` bans, and none of
/// those three caught it.
///
/// The code is removed rather than left behind the reply refusal (#534 phase 1),
/// and this guard keeps it removed. Attachments on the reply path come back in
/// #608 through Mail's editor (⇧⌘A), which does not need this command, so the
/// guard stays after #608 lands.
///
/// Scanned over whole file text and comment-agnostic, for the reasons
/// `NoBodyInjectionGuardTests` documents. Prose under `Sources/CheAppleMailMCP/`
/// must therefore not spell the banned form; this file names it only inside the
/// regex literal below.
final class NoObjectModelAttachmentGuardTests: XCTestCase {

    private func serverSourcesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <package root>/
            .appendingPathComponent("Sources/CheAppleMailMCP")
    }

    func testNoSourceFileInsertsAnAttachmentThroughTheObjectModel() throws {
        let insertion = try NSRegularExpression(pattern: #"make\s+new\s+attachment"#)

        var offenders: [String] = []
        for url in try swiftFiles() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for m in insertion.matches(in: text, range: range) {
                offenders.append("\(url.lastPathComponent):\(line(of: m.range, in: text))")
            }
        }

        XCTAssertTrue(offenders.isEmpty,
            "Inserting an attachment through Mail's object model writes the message's content "
            + "and drops the body pasted through the editor and Mail's quote, while the call "
            + "reports success (#534). Attach through Mail's editor instead (#608):\n"
            + offenders.joined(separator: "\n"))
    }

    /// An empty scan would pass the guard above for the wrong reason (a moved
    /// directory, a wrong path). The server's composing code must be in the scan.
    func testScanCoversTheComposingSources() throws {
        let names = Set(try swiftFiles().map(\.lastPathComponent))
        for expected in ["ComposeScriptBuilder.swift", "MailController.swift", "MailtoCompose.swift"] {
            XCTAssertTrue(names.contains(expected),
                          "the guard must scan \(expected); found \(names.count) files")
        }
    }

    // MARK: - Helpers

    private func swiftFiles() throws -> [URL] {
        let root = serverSourcesDir()
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
