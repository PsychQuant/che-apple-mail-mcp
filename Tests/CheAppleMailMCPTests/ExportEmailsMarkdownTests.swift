import XCTest
@testable import CheAppleMailMCP
@testable import MailSQLite

final class ExportEmailsMarkdownTests: XCTestCase {

    private func makeEmail(
        subject: String = "Topic",
        sender: String = "Joanne Peng <peng.cyj@gmail.com>",
        date: String = "Sat, 13 Jun 2026 16:01:14 +0800",
        messageId: String = "<m@x>",
        inReplyTo: String = "",
        textBody: String? = "body",
        htmlBody: String? = nil
    ) -> EmailContent {
        EmailContent(
            subject: subject, sender: sender, toRecipients: ["a@x.com"], ccRecipients: [],
            date: date, messageId: messageId, inReplyTo: inReplyTo,
            textBody: textBody, htmlBody: htmlBody, rawSource: nil)
    }

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("idd193-export-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    // MARK: - Pure helpers

    func testAttachmentClass() {
        XCTAssertEqual(ExportEmailsMarkdown.attachmentClass("data.csv"), "data")
        XCTAssertEqual(ExportEmailsMarkdown.attachmentClass("sheet.XLSX"), "data")  // case-insensitive
        XCTAssertEqual(ExportEmailsMarkdown.attachmentClass("report.pdf"), "document")
        XCTAssertEqual(ExportEmailsMarkdown.attachmentClass("noext"), "document")
    }

    func testSlug() {
        XCTAssertEqual(ExportEmailsMarkdown.slug("4 papers using MB3.5"), "4-papers-using-MB3-5")
        XCTAssertEqual(ExportEmailsMarkdown.slug("中文 主旨"), "中文-主旨")  // CJK preserved
        XCTAssertEqual(ExportEmailsMarkdown.slug("!!!"), "no-subject")     // all punctuation
        XCTAssertEqual(ExportEmailsMarkdown.slug(String(repeating: "a", count: 80)).count, 50)
    }

    func testDefaultFilename_collisionSuffix() {
        var seen: [String: Int] = [:]
        let f1 = ExportEmailsMarkdown.defaultFilename(localDate: "2026-06-13", threadKey: "Topic", seen: &seen)
        let f2 = ExportEmailsMarkdown.defaultFilename(localDate: "2026-06-13", threadKey: "Topic", seen: &seen)
        let f3 = ExportEmailsMarkdown.defaultFilename(localDate: "2026-06-13", threadKey: "Topic", seen: &seen)
        XCTAssertEqual(f1, "2026-06-13_Topic.md")
        XCTAssertEqual(f2, "2026-06-13_Topic-1.md")
        XCTAssertEqual(f3, "2026-06-13_Topic-2.md")
    }

    func testApplyTemplate() {
        let name = ExportEmailsMarkdown.applyTemplate(
            "{date}__{subject}", localDate: "2026-06-13", threadKey: "Hello World",
            sender: "x@y.com", messageId: "<m>")
        XCTAssertEqual(name, "2026-06-13__Hello-World.md")
    }

    // MARK: - Write-safety helpers (pure)

    func testIsSafeSegment() {
        XCTAssertTrue(ExportEmailsMarkdown.isSafeSegment("report.pdf"))
        XCTAssertTrue(ExportEmailsMarkdown.isSafeSegment("中文 檔名.csv"))
        XCTAssertFalse(ExportEmailsMarkdown.isSafeSegment("../escape.txt"))   // traversal
        XCTAssertFalse(ExportEmailsMarkdown.isSafeSegment("a/b.txt"))         // separator
        XCTAssertFalse(ExportEmailsMarkdown.isSafeSegment("a\\b.txt"))        // backslash
        XCTAssertFalse(ExportEmailsMarkdown.isSafeSegment(".."))
        XCTAssertFalse(ExportEmailsMarkdown.isSafeSegment("."))
        XCTAssertFalse(ExportEmailsMarkdown.isSafeSegment(""))
        XCTAssertFalse(ExportEmailsMarkdown.isSafeSegment("evil\u{0}.txt"))   // NUL
    }

    func testSanitizeSegment() {
        XCTAssertEqual(ExportEmailsMarkdown.sanitizeSegment("../../evil"), "..-..-evil")
        XCTAssertEqual(ExportEmailsMarkdown.sanitizeSegment("a/b\\c"), "a-b-c")
        XCTAssertEqual(ExportEmailsMarkdown.sanitizeSegment(".."), "untitled")
        XCTAssertEqual(ExportEmailsMarkdown.sanitizeSegment("   "), "untitled")
        XCTAssertEqual(ExportEmailsMarkdown.sanitizeSegment("normal name"), "normal name")
    }

    func testUniquify_addsSuffixOnRepeat() {
        var used: Set<String> = []
        XCTAssertEqual(ExportEmailsMarkdown.uniquify("a.md", used: &used), "a.md")
        XCTAssertEqual(ExportEmailsMarkdown.uniquify("a.md", used: &used), "a-1.md")
        XCTAssertEqual(ExportEmailsMarkdown.uniquify("a.md", used: &used), "a-2.md")
    }

    // MARK: - Write-safety orchestration (the CRITICALs from idd-verify #193)

    func testRun_rejectsAttachmentPathTraversal() throws {
        let out = tempDir()
        let parent = out.deletingLastPathComponent()
        let evil = parent.appendingPathComponent("escape_PWNED.txt")
        try? FileManager.default.removeItem(at: evil)
        addTeardownBlock { try? FileManager.default.removeItem(at: evil) }

        let manifest = ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: out, direction: "received",
            includeAttachments: true, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(subject: "Att") },
            attachmentNamesFor: { _ in ["../../escape_PWNED.txt"] },
            saveAttachment: { _, _, dest in try Data("x".utf8).write(to: dest) })

        // The malicious attachment must NOT have escaped output_dir.
        XCTAssertFalse(FileManager.default.fileExists(atPath: evil.path),
                       "attachment with ../ must not be written outside output_dir")
        let item = manifest.items[0]
        XCTAssertEqual(item.status, "written")          // the .md still succeeds
        XCTAssertTrue(item.attachments.isEmpty)         // traversal attachment skipped
        XCTAssertFalse(item.attachmentErrors.isEmpty)   // recorded, not silently dropped
    }

    func testRun_perIdOverride_pathTraversalContained() throws {
        let out = tempDir()
        let parentEvil = out.deletingLastPathComponent().appendingPathComponent("evil.md")
        try? FileManager.default.removeItem(at: parentEvil)
        addTeardownBlock { try? FileManager.default.removeItem(at: parentEvil) }

        let manifest = ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil,
            filenameOverrides: ["10": "../../evil"], extraFrontmatter: [],
            fetch: { _ in self.makeEmail(subject: "Override") },
            attachmentNamesFor: { _ in [] },
            saveAttachment: { _, _, _ in })

        XCTAssertFalse(FileManager.default.fileExists(atPath: parentEvil.path),
                       "per-id override with ../ must not write outside output_dir")
        let item = manifest.items[0]
        XCTAssertEqual(item.status, "written")
        // The written file stays inside output_dir (separators collapsed).
        XCTAssertTrue(item.writtenPath!.hasPrefix(out.path + "/"))
    }

    func testRun_templateCollision_noSilentOverwrite() throws {
        let out = tempDir()
        // Both emails resolve to the same template name → must NOT overwrite.
        let manifest = ExportEmailsMarkdown.run(
            ids: ["10", "11"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: "{date}", filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(subject: "Whatever") },
            attachmentNamesFor: { _ in [] },
            saveAttachment: { _, _, _ in })

        XCTAssertEqual(manifest.written, 2)
        let paths = Set(manifest.items.compactMap { $0.writtenPath })
        XCTAssertEqual(paths.count, 2, "two emails must produce two distinct files, not overwrite")
        for p in paths { XCTAssertTrue(FileManager.default.fileExists(atPath: p)) }
    }

    func testRun_attachmentSaveFailure_recordedInManifest() throws {
        let out = tempDir()
        struct Boom: Error {}
        let manifest = ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: out, direction: "received",
            includeAttachments: true, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(subject: "AttFail") },
            attachmentNamesFor: { _ in ["report.pdf"] },
            saveAttachment: { _, _, _ in throw Boom() })

        let item = manifest.items[0]
        XCTAssertEqual(item.status, "written")          // email markdown still written
        XCTAssertTrue(item.attachments.isEmpty)
        XCTAssertFalse(item.attachmentErrors.isEmpty,   // failure surfaced, not swallowed
                       "attachment save failure must be recorded in the manifest")
    }

    // MARK: - Orchestration (injected fakes, real temp dir)

    func testRun_writesMarkdownAndManifest() throws {
        let out = tempDir()
        let emails = ["10": makeEmail(subject: "First"), "11": makeEmail(subject: "Second")]
        let manifest = ExportEmailsMarkdown.run(
            ids: ["10", "11"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { emails[$0]! },
            attachmentNamesFor: { _ in [] },
            saveAttachment: { _, _, _ in })

        XCTAssertEqual(manifest.written, 2)
        XCTAssertEqual(manifest.errors, 0)
        for item in manifest.items {
            XCTAssertEqual(item.status, "written")
            XCTAssertNotNil(item.writtenPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.writtenPath!))
        }
    }

    // MARK: - #198 in_reply_to threading + #199 body_type frontmatter

    private func readWrittenMd(_ manifest: ExportManifest) throws -> String {
        let path = try XCTUnwrap(manifest.items.first?.writtenPath)
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func runOne(_ email: EmailContent, extra: [(String, String)] = []) -> ExportManifest {
        ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: tempDir(), direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: extra,
            fetch: { _ in email },
            attachmentNamesFor: { _ in [] },
            saveAttachment: { _, _, _ in })
    }

    func testRun_threadsInReplyToIntoFrontmatter() throws {
        let md = try readWrittenMd(runOne(makeEmail(inReplyTo: "<parent@example.com>")))
        XCTAssertTrue(md.contains("in_reply_to: \"<parent@example.com>\""),
                      "#198: in_reply_to must be threaded from EmailContent, not hard-coded empty:\n\(md)")
    }

    func testRun_inReplyToEmptyWhenAbsent() throws {
        let md = try readWrittenMd(runOne(makeEmail(inReplyTo: "")))
        XCTAssertTrue(md.contains("in_reply_to: \"\""),
                      "absent In-Reply-To → empty (preserves prior behavior)")
    }

    func testRun_bodyTypeText_whenTextBodyPresent() throws {
        let md = try readWrittenMd(runOne(makeEmail(textBody: "plain body", htmlBody: nil)))
        XCTAssertTrue(md.contains("body_type: \"text\""), "#199: text body → body_type text:\n\(md)")
    }

    func testRun_bodyTypeHtml_whenHtmlOnly() throws {
        let md = try readWrittenMd(runOne(makeEmail(textBody: nil, htmlBody: "<p>only html</p>")))
        XCTAssertTrue(md.contains("body_type: \"html\""), "#199: html-only body → body_type html:\n\(md)")
    }

    func testRun_bodyTypeCoexistsWithCallerExtraFrontmatter() throws {
        // body_type is appended AFTER caller-supplied extraFrontmatter; both appear.
        let md = try readWrittenMd(runOne(makeEmail(textBody: "x"), extra: [("account", "work")]))
        XCTAssertTrue(md.contains("account: \"work\""), "caller extra preserved")
        XCTAssertTrue(md.contains("body_type: \"text\""), "body_type added alongside caller extras")
    }

    func testRun_partialFailure_continues() throws {
        let out = tempDir()
        struct Boom: Error {}
        let manifest = ExportEmailsMarkdown.run(
            ids: ["10", "bad", "11"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { id in if id == "bad" { throw Boom() }; return self.makeEmail(subject: "S\(id)") },
            attachmentNamesFor: { _ in [] },
            saveAttachment: { _, _, _ in })

        XCTAssertEqual(manifest.written, 2)
        XCTAssertEqual(manifest.errors, 1)
        let errItem = manifest.items.first { $0.status == "error" }
        XCTAssertEqual(errItem?.id, "bad")
        XCTAssertNotNil(errItem?.error)
    }

    func testRun_collisionSuffix_onDisk() throws {
        let out = tempDir()
        // Two emails, same date + same subject → second gets -1 suffix.
        let manifest = ExportEmailsMarkdown.run(
            ids: ["10", "11"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(subject: "Same Topic") },
            attachmentNamesFor: { _ in [] },
            saveAttachment: { _, _, _ in })

        let names = Set(manifest.items.compactMap { $0.writtenPath.map { ($0 as NSString).lastPathComponent } })
        XCTAssertTrue(names.contains("2026-06-13_Same-Topic.md"))
        XCTAssertTrue(names.contains("2026-06-13_Same-Topic-1.md"))
    }

    func testRun_includeAttachments_routesByClass() throws {
        let out = tempDir()
        let manifest = ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: out, direction: "received",
            includeAttachments: true, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(subject: "WithAtt") },
            attachmentNamesFor: { _ in ["report.pdf", "data.csv"] },
            saveAttachment: { _, name, dest in
                // Fake: write a placeholder file at dest (parent dir made by core).
                try Data("x".utf8).write(to: dest)
            })

        let item = manifest.items[0]
        XCTAssertEqual(item.status, "written")
        XCTAssertTrue(item.attachments.contains("attachments/2026-06-13_WithAtt/report.pdf"))
        XCTAssertTrue(item.attachments.contains("data/data.csv"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: out.appendingPathComponent("attachments/2026-06-13_WithAtt/report.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: out.appendingPathComponent("data/data.csv").path))
        // Markdown should reference the attachments.
        let md = try String(contentsOf: URL(fileURLWithPath: item.writtenPath!), encoding: .utf8)
        XCTAssertTrue(md.contains("Attachments:"))
        XCTAssertTrue(md.contains("data/data.csv"))
    }
}
