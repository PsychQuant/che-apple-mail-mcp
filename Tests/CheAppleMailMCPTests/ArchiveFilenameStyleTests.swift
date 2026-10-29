import XCTest
import MCP
import MailSQLite
@testable import CheAppleMailMCP

final class ArchiveFilenameStyleTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func export(
        _ subjects: [String], date: String = "Fri, 06 Mar 2026 23:49:56 -0500",
        into dir: URL, style: ExportFilenameStyle = .archiveMail,
        template: String? = nil, overrides: [String: String] = [:]
    ) throws -> ExportManifest {
        try ExportEmailsMarkdown.run(
            ids: subjects.indices.map(String.init), outputDir: dir, ownAddresses: [],
            fallbackDirection: "received", includeAttachments: false,
            filenameTemplate: template, filenameOverrides: overrides, extraFrontmatter: [],
            filenameStyle: style,
            fetch: { id in
                EmailContent(subject: subjects[Int(id)!], sender: "sender@example.invalid",
                             toRecipients: [], ccRecipients: [], date: date,
                             messageId: "<\(id)@example.invalid>", inReplyTo: "", textBody: "body",
                             htmlBody: nil, rawSource: nil)
            }, attachmentNamesFor: { _ in [] }, attachmentData: { _, _ in Data() })
    }

    func testRawReplyAndUnicode() {
        XCTAssertEqual(ExportEmailsMarkdown.archiveMailSlug("Re: 中文 🇹🇼 👩‍👩‍👧‍👦 e\u{301}"),
                       "Re--中文-🇹🇼-👩‍👩‍👧‍👦-e\u{301}")
        XCTAssertEqual(ExportEmailsMarkdown.archiveMailSlug("Re: a / b\\c?。!"), "Re--a---b-c")
        XCTAssertEqual(ExportEmailsMarkdown.archiveMailSlug("a\u{0}b\u{7f}c\u{85}d"), "a-b-c-d")
        XCTAssertEqual(ExportEmailsMarkdown.archiveMailSlug(".. / ?"), "no-subject")
        XCTAssertEqual(ExportEmailsMarkdown.archiveMailSlug(""), "no-subject")
    }

    func testFiftyGraphemesBeforeTrimming() {
        for grapheme in ["e\u{301}", "🇹🇼", "👩‍👩‍👧‍👦", "中"] {
            let input = String(repeating: grapheme, count: 51)
            XCTAssertEqual(ExportEmailsMarkdown.archiveMailSlug(input), String(repeating: grapheme, count: 50))
        }
        XCTAssertEqual(ExportEmailsMarkdown.archiveMailSlug(" " + String(repeating: "a", count: 50)),
                       String(repeating: "a", count: 49))
        XCTAssertEqual(ExportEmailsMarkdown.archiveMailSlug(String(repeating: "a", count: 49) + " :tail"),
                       String(repeating: "a", count: 49))
    }

    func testStrictStyleOption() throws {
        XCTAssertEqual(try parseExportFilenameStyle(nil), .default)
        XCTAssertEqual(try parseExportFilenameStyle(.string("default")), .default)
        XCTAssertEqual(try parseExportFilenameStyle(.string("archive-mail")), .archiveMail)
        for bad: Value in [.null, .bool(true), .int(1), .string("archive"), .string("ARCHIVE-MAIL"), .object([:])] {
            XCTAssertThrowsError(try parseExportFilenameStyle(bad)) { error in
                XCTAssertTrue(String(describing: error).contains("filename_style"))
            }
        }
    }

    func testBothAliasesAdvertiseStyle() throws {
        let tools = CheAppleMailMCPServer.defineTools()
        for name in ["batch_export_emails_markdown", "export_emails_markdown"] {
            let tool = try XCTUnwrap(tools.first { $0.name == name })
            guard case .object(let schema) = tool.inputSchema,
                  case .object(let properties)? = schema["properties"],
                  case .object(let opts)? = properties["opts"],
                  case .object(let options)? = opts["properties"],
                  case .object(let style)? = options["filename_style"] else {
                return XCTFail("missing filename_style schema")
            }
            XCTAssertEqual(style["enum"], Value.array([.string("default"), .string("archive-mail")]))
            XCTAssertEqual(style["default"], Value.string("default"))
        }
    }

    func testDateOffsetMatchesActualFrontmatter() throws {
        let cases = [
            ("Fri, 06 Mar 2026 23:49:56 -0500", "2026-03-06T23:49:56-05:00"),
            ("Sat, 07 Mar 2026 00:49:56 +0800", "2026-03-07T00:49:56+08:00"),
            ("Fri, 06 Mar 2026 18:49:56 +0000", "2026-03-06T18:49:56Z")
        ]
        for (header, iso) in cases {
            let manifest = try export(["Re: x"], date: header, into: directory())
            let item = try XCTUnwrap(manifest.items.first)
            XCTAssertEqual(item.status, "written")
            let path = try XCTUnwrap(item.writtenPath)
            XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "\(iso.prefix(10))_Re--x.md")
            let markdown = try String(contentsOfFile: path, encoding: .utf8)
            XCTAssertTrue(markdown.contains("\ndate: \(iso)\n"))
            XCTAssertTrue(markdown.contains("\nthread_key: \"x\"\n"), "filename style must not change threading")
        }
    }

    func testUnknownDateDoesNotGuess() throws {
        let manifest = try export(["x"], date: "not a date", into: directory())
        let path = try XCTUnwrap(manifest.items.first?.writtenPath)
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "unknown-date_x.md")
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains("\ndate: not a date\n"))
    }

    func testDiskAndBatchCollisionsShareOneSequence() throws {
        let dir = try directory()
        let original = dir.appendingPathComponent("2026-03-06_RE--X.md")
        try "original".write(to: original, atomically: true, encoding: .utf8)
        let first = try export(["Re: x", "Re: x"], into: dir)
        XCTAssertEqual(first.items.compactMap(\.writtenPath).map { URL(fileURLWithPath: $0).lastPathComponent },
                       ["2026-03-06_Re--x-1.md", "2026-03-06_Re--x-2.md"])
        let second = try export(["Re: x"], into: dir)
        XCTAssertEqual(second.items.compactMap(\.writtenPath).map { URL(fileURLWithPath: $0).lastPathComponent },
                       ["2026-03-06_Re--x-3.md"])
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
    }

    func testFirstNameHasNoSuffix() throws {
        let manifest = try export(["Re: x", "Re: x"], into: directory())
        XCTAssertEqual(manifest.items.compactMap(\.writtenPath).map { URL(fileURLWithPath: $0).lastPathComponent },
                       ["2026-03-06_Re--x.md", "2026-03-06_Re--x-1.md"])
    }

    func testOverrideThenTemplateThenStyle() throws {
        let dir = try directory()
        let manifest = try export(["Re: x", "Re: x"], into: dir,
                                  template: "template-{subject}", overrides: ["0": "chosen"])
        XCTAssertEqual(manifest.items.compactMap(\.writtenPath).map { URL(fileURLWithPath: $0).lastPathComponent },
                       ["chosen.md", "template-x.md"])
        let mixed = try export(["Re: x", "Re: x"], into: dir, overrides: ["0": "2026-03-06_Re--x"])
        XCTAssertEqual(mixed.items.compactMap(\.writtenPath).map { URL(fileURLWithPath: $0).lastPathComponent },
                       ["2026-03-06_Re--x.md", "2026-03-06_Re--x-1.md"])
    }

    func testLegacyDefaultStillStripsReplyAndCollapsesDashes() throws {
        let manifest = try export(["Re: x : y", "Re: x : y"], into: directory(), style: .default)
        XCTAssertEqual(manifest.items.compactMap(\.writtenPath).map { URL(fileURLWithPath: $0).lastPathComponent },
                       ["2026-03-06_x-y.md", "2026-03-06_x-y-1.md"])
    }
}
