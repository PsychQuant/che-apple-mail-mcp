import XCTest
@testable import CheAppleMailMCP
@testable import MailSQLite

final class ExportEmailsMarkdownTests: XCTestCase {

    private func makeEmail(
        subject: String = "Topic",
        sender: String = "Joanne Peng <peng.cyj@gmail.com>",
        date: String = "Sat, 13 Jun 2026 16:01:14 +0800",
        messageId: String = "<m@x>",
        textBody: String? = "body"
    ) -> EmailContent {
        EmailContent(
            subject: subject, sender: sender, toRecipients: ["a@x.com"], ccRecipients: [],
            date: date, messageId: messageId, textBody: textBody, htmlBody: nil, rawSource: nil)
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
