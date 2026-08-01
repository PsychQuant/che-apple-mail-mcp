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
        htmlBody: String? = nil,
        fromPartialEmlx: Bool = false
    ) -> EmailContent {
        EmailContent(
            subject: subject, sender: sender, toRecipients: ["a@x.com"], ccRecipients: [],
            date: date, messageId: messageId, inReplyTo: inReplyTo,
            textBody: textBody, htmlBody: htmlBody, rawSource: nil,
            fromPartialEmlx: fromPartialEmlx)
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

        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: out, direction: "received",
            includeAttachments: true, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(subject: "Att") },
            attachmentNamesFor: { _ in ["../../escape_PWNED.txt"] },
            attachmentData: { _, _ in Data("x".utf8) })

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

        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil,
            filenameOverrides: ["10": "../../evil"], extraFrontmatter: [],
            fetch: { _ in self.makeEmail(subject: "Override") },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() })

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
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10", "11"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: "{date}", filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(subject: "Whatever") },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() })

        XCTAssertEqual(manifest.written, 2)
        let paths = Set(manifest.items.compactMap { $0.writtenPath })
        XCTAssertEqual(paths.count, 2, "two emails must produce two distinct files, not overwrite")
        for p in paths { XCTAssertTrue(FileManager.default.fileExists(atPath: p)) }
    }

    func testRun_attachmentSaveFailure_recordedInManifest() throws {
        let out = tempDir()
        struct Boom: Error {}
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: out, direction: "received",
            includeAttachments: true, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(subject: "AttFail") },
            attachmentNamesFor: { _ in ["report.pdf"] },
            attachmentData: { _, _ in throw Boom() })

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
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10", "11"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { emails[$0]! },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() })

        XCTAssertEqual(manifest.written, 2)
        XCTAssertEqual(manifest.errors, 0)
        for item in manifest.items {
            XCTAssertEqual(item.status, "written")
            XCTAssertNotNil(item.writtenPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.writtenPath!))
        }
    }

    // MARK: - #232 cross-call filename collision (must not silently overwrite)

    /// A second `run()` to the SAME outputDir must not reuse a filename already
    /// on disk from an earlier call. Before #232 the `-N` collision suffix only
    /// tracked names emitted *within one call* (in-memory `usedFilenames`), so a
    /// mixed-direction corpus split into two calls (forced by the single
    /// `direction` param) silently overwrote same-(date,slug) files.
    ///
    /// Each call writes id-distinct BODY content and the earlier file is read
    /// back, so the test proves the first file's *content survives* — not merely
    /// that two path strings differ (a same-content test would still pass on a
    /// silent clobber). Covers both the default (date,slug) branch and the
    /// caller-supplied `filenameTemplate` branch.
    // MARK: - #313: case-only filename collisions (APFS is case-insensitive)

    /// Unit level: the guard itself must treat `Re--X.md` / `RE--X.md` as the
    /// SAME family. On APFS (case-insensitive, case-preserving — the macOS
    /// default) they are one directory entry, and treating them as distinct let
    /// the second silently overwrite the first (#313, P0 data loss).
    func testUniquify_caseVariantCollision_getsSuffix() {
        var used: Set<String> = []
        let first = ExportEmailsMarkdown.uniquify("Re--X.md", used: &used)
        XCTAssertEqual(first, "Re--X.md")
        let second = ExportEmailsMarkdown.uniquify("RE--X.md", used: &used)
        XCTAssertEqual(second, "RE--X-1.md",
            "a case-variant of an already-used name MUST get a -N suffix — on APFS "
            + "it is the same file (#313)")
        // And the suffix allocation itself must be case-folded too.
        let third = ExportEmailsMarkdown.uniquify("re--x.md", used: &used)
        XCTAssertEqual(third, "re--x-2.md", "the whole family shares one -N sequence")
    }

    /// Single call, two override filenames differing only by case — the issue's
    /// Exchange (`RE:`) vs Apple Mail (`Re:`) scenario. Content comparison, not
    /// path comparison: distinct returned paths with only one surviving file is
    /// precisely the silent-loss shape being pinned (#313).
    func testRun_caseOnlyCollision_singleCall_noSilentOverwrite() throws {
        let out = tempDir()
        let m = try ExportEmailsMarkdown.run(
            ids: ["1", "2"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil,
            filenameOverrides: ["1": "2026-07-18_Re--Some-subject.md",
                                "2": "2026-07-18_RE--Some-subject.md"],
            extraFrontmatter: [],
            fetch: { id in self.makeEmail(subject: "S", textBody: "BODY-\(id)") },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() })

        XCTAssertEqual(m.items.filter { $0.status == "written" }.count, 2)
        let paths = m.items.compactMap(\.writtenPath)
        XCTAssertEqual(Set(paths.map { $0.lowercased() }).count, 2,
            "the two written_paths must differ beyond letter case — same-case-folded "
            + "paths are one APFS file (#313)")
        let contents = try paths.map { try String(contentsOfFile: $0, encoding: .utf8) }
        XCTAssertTrue(contents.contains { $0.contains("BODY-1") },
                      "email 1's content must survive (#313)")
        XCTAssertTrue(contents.contains { $0.contains("BODY-2") },
                      "email 2's content must survive (#313)")
    }

    /// Cross-call variant — the issue's literal reproduction: call 1 archives the
    /// `Re:` side, call 2 (fresh run, seeded only from the on-disk scan) archives
    /// the `RE:` side.
    func testRun_caseOnlyCollision_crossCall_secondCallDoesNotOverwriteFirst() throws {
        let out = tempDir()
        func exportOnce(_ id: String, name: String, body: String) throws -> String {
            let m = try ExportEmailsMarkdown.run(
                ids: [id], outputDir: out, direction: "received",
                includeAttachments: false, filenameTemplate: nil,
                filenameOverrides: [id: name], extraFrontmatter: [],
                fetch: { _ in self.makeEmail(subject: "S", textBody: body) },
                attachmentNamesFor: { _ in [] },
                attachmentData: { _, _ in Data() })
            return try XCTUnwrap(m.items.first?.writtenPath)
        }
        let p1 = try exportOnce("A", name: "2026-07-18_Re--Some-subject.md", body: "SENT-SIDE")
        let p2 = try exportOnce("B", name: "2026-07-18_RE--Some-subject.md", body: "RECEIVED-SIDE")

        XCTAssertNotEqual(p1.lowercased(), p2.lowercased(),
            "second call's case-variant must be uniquified against the on-disk seed (#313)")
        XCTAssertTrue(try String(contentsOfFile: p1, encoding: .utf8).contains("SENT-SIDE"),
            "call 1's file must not be clobbered by call 2 (#313)")
        XCTAssertTrue(try String(contentsOfFile: p2, encoding: .utf8).contains("RECEIVED-SIDE"))
    }

    func testRun_crossCallCollision_secondCallDoesNotOverwriteFirst() throws {
        let out = tempDir()

        func exportOnce(_ id: String, body: String, template: String? = nil) throws -> String {
            let m = try ExportEmailsMarkdown.run(
                ids: [id], outputDir: out, direction: "received",
                includeAttachments: false, filenameTemplate: template, filenameOverrides: [:],
                extraFrontmatter: [],
                fetch: { _ in self.makeEmail(subject: "Report", textBody: body) },
                attachmentNamesFor: { _ in [] },
                attachmentData: { _, _ in Data() })
            return try XCTUnwrap(m.items.first?.writtenPath)
        }

        // --- default (date,slug) branch: same subject+date → same base name ---
        let path1 = try exportOnce("10", body: "FIRST-CALL-BODY")
        let path2 = try exportOnce("11", body: "SECOND-CALL-BODY")
        XCTAssertNotEqual(path1, path2,
            "second export must not reuse the first call's filename (#232)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path2))
        // Content proof: call 1's file still holds call 1's body (not clobbered).
        XCTAssertTrue(try String(contentsOfFile: path1, encoding: .utf8).contains("FIRST-CALL-BODY"),
            "first call's content must survive the second export (#232)")
        XCTAssertTrue(try String(contentsOfFile: path2, encoding: .utf8).contains("SECOND-CALL-BODY"))

        // --- template branch: a fixed template yields the same name each call ---
        let tpl = "fixed-name"   // no placeholders → "fixed-name.md" every call
        let tpath1 = try exportOnce("20", body: "TPL-FIRST", template: tpl)
        let tpath2 = try exportOnce("21", body: "TPL-SECOND", template: tpl)
        XCTAssertNotEqual(tpath1, tpath2,
            "template branch must also continue the -N suffix across calls (#232)")
        XCTAssertTrue(try String(contentsOfFile: tpath1, encoding: .utf8).contains("TPL-FIRST"),
            "template branch: first call's content must survive (#232)")
    }

    // MARK: - #198 in_reply_to threading + #199 body_type frontmatter

    private func readWrittenMd(_ manifest: ExportManifest) throws -> String {
        let path = try XCTUnwrap(manifest.items.first?.writtenPath)
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func runOne(_ email: EmailContent, extra: [(String, String)] = []) throws -> ExportManifest {
        try ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: tempDir(), direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: extra,
            fetch: { _ in email },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() })
    }

    func testRun_threadsInReplyToIntoFrontmatter() throws {
        let md = try readWrittenMd(try runOne(makeEmail(inReplyTo: "<parent@example.com>")))
        XCTAssertTrue(md.contains("in_reply_to: \"<parent@example.com>\""),
                      "#198: in_reply_to must be threaded from EmailContent, not hard-coded empty:\n\(md)")
    }

    func testRun_inReplyToEmptyWhenAbsent() throws {
        let md = try readWrittenMd(try runOne(makeEmail(inReplyTo: "")))
        XCTAssertTrue(md.contains("in_reply_to: \"\""),
                      "absent In-Reply-To → empty (preserves prior behavior)")
    }

    func testRun_bodyTypeText_whenTextBodyPresent() throws {
        let md = try readWrittenMd(try runOne(makeEmail(textBody: "plain body", htmlBody: nil)))
        XCTAssertTrue(md.contains("body_type: \"text\""), "#199: text body → body_type text:\n\(md)")
    }

    func testRun_bodyTypeHtml_whenHtmlOnly() throws {
        let md = try readWrittenMd(try runOne(makeEmail(textBody: nil, htmlBody: "<p>only html</p>")))
        XCTAssertTrue(md.contains("body_type: \"html\""), "#199: html-only body → body_type html:\n\(md)")
    }

    func testRun_bodyTypeCoexistsWithCallerExtraFrontmatter() throws {
        // body_type is appended AFTER caller-supplied extraFrontmatter; both appear.
        let md = try readWrittenMd(try runOne(makeEmail(textBody: "x"), extra: [("account", "work")]))
        XCTAssertTrue(md.contains("account: \"work\""), "caller extra preserved")
        XCTAssertTrue(md.contains("body_type: \"text\""), "body_type added alongside caller extras")
    }

    func testRun_partialFailure_continues() throws {
        let out = tempDir()
        struct Boom: Error {}
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10", "bad", "11"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { id in if id == "bad" { throw Boom() }; return self.makeEmail(subject: "S\(id)") },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() })

        XCTAssertEqual(manifest.written, 2)
        XCTAssertEqual(manifest.errors, 1)
        let errItem = manifest.items.first { $0.status == "error" }
        XCTAssertEqual(errItem?.id, "bad")
        XCTAssertNotNil(errItem?.error)
    }

    func testRun_collisionSuffix_onDisk() throws {
        let out = tempDir()
        // Two emails, same date + same subject → second gets -1 suffix.
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10", "11"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(subject: "Same Topic") },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() })

        let names = Set(manifest.items.compactMap { $0.writtenPath.map { ($0 as NSString).lastPathComponent } })
        XCTAssertTrue(names.contains("2026-06-13_Same-Topic.md"))
        XCTAssertTrue(names.contains("2026-06-13_Same-Topic-1.md"))
    }

    func testRun_includeAttachments_routesByClass() throws {
        let out = tempDir()
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: out, direction: "received",
            includeAttachments: true, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(subject: "WithAtt") },
            attachmentNamesFor: { _ in ["report.pdf", "data.csv"] },
            attachmentData: { _, _ in
                // Fake: placeholder bytes (the export owns the race-free write).
                Data("x".utf8)
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

    // MARK: - #177 dedup skip-set

    func testRun_skipMessageIds_skipsAlreadyArchived() throws {
        let out = tempDir()
        // id "10" → already archived (Message-ID in the skip set); id "11" → new.
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10", "11"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { id in self.makeEmail(subject: "S\(id)", messageId: "<\(id)@x>") },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() },
            skipMessageIds: ["<10@x>"])

        let byId = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.id, $0) })
        XCTAssertEqual(byId["10"]?.status, "skipped", "an already-archived Message-ID must be skipped")
        XCTAssertEqual(byId["10"]?.messageId, "<10@x>")
        XCTAssertNil(byId["10"]?.writtenPath, "a skipped email must not be written")
        XCTAssertEqual(byId["11"]?.status, "written")
        XCTAssertEqual(manifest.skipped, 1)
        XCTAssertEqual(manifest.written, 1)
        XCTAssertEqual(manifest.jsonObject["skipped"] as? Int, 1)
    }

    func testRun_noSkipSet_skippedCountZeroAndAllWritten() throws {
        let out = tempDir()
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(messageId: "<10@x>") },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() })
        XCTAssertEqual(manifest.skipped, 0)
        XCTAssertEqual(manifest.items[0].status, "written")
        // written items carry message_id (already present; pinned here for #177)
        XCTAssertEqual(manifest.items[0].messageId, "<10@x>")
    }

    // MARK: - #283 partial-.emlx visibility (closes the #274 gap on the bulk path)

    func testRun_partialBodyMissing_annotatedAndStillWritten() throws {
        // #283 default behavior: a partial-.emlx email whose body is absent is
        // STILL written (byte-compatible with pre-#283 runs) but the manifest
        // item carries `body_downloaded: false` — the bulk path stops being
        // silent about header-only archives. Negative-only key (#274 parity):
        // false or absent, never true.
        let out = tempDir()
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10", "11"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { id in
                id == "10"
                    ? self.makeEmail(subject: "P", messageId: "<10@x>",
                                     textBody: nil, fromPartialEmlx: true)
                    : self.makeEmail(subject: "N", messageId: "<11@x>")
            },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() })

        let byId = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.id, $0) })
        XCTAssertEqual(byId["10"]?.status, "written",
                       "default (skip_partial off) still writes — annotation, not omission")
        XCTAssertEqual(byId["10"]?.bodyDownloaded, false)
        XCTAssertEqual(byId["10"]?.jsonObject["body_downloaded"] as? Bool, false)
        XCTAssertNil(byId["11"]?.bodyDownloaded)
        XCTAssertNil(byId["11"]?.jsonObject["body_downloaded"],
                     "non-partial items must not carry the key (negative-only contract)")
        XCTAssertEqual(manifest.bodyNotDownloaded, 1)
        XCTAssertEqual(manifest.jsonObject["body_not_downloaded"] as? Int, 1)
    }

    func testRun_partialBodyMissing_skipPartial_headerOnlyNotWritten() throws {
        // #283 opt-in: skip_partial=true → the header-only email is NOT written
        // (status "header_only", no path, no file) so the corpus never gets a
        // header-only .md; the SOP re-fetches flagged ids (get_email nudges the
        // download) and re-runs export for just those ids — no stale-file
        // cleanup, no collision-guard -N duplicates.
        let out = tempDir()
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10", "11"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { id in
                id == "10"
                    ? self.makeEmail(subject: "P", messageId: "<10@x>",
                                     textBody: nil, fromPartialEmlx: true)
                    : self.makeEmail(subject: "N", messageId: "<11@x>")
            },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() },
            skipPartial: true)

        let byId = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.id, $0) })
        XCTAssertEqual(byId["10"]?.status, "header_only")
        XCTAssertNil(byId["10"]?.writtenPath)
        XCTAssertEqual(byId["10"]?.bodyDownloaded, false)
        XCTAssertEqual(byId["11"]?.status, "written")
        XCTAssertEqual(manifest.bodyNotDownloaded, 1)
        XCTAssertEqual(manifest.written, 1)
        // Nothing on disk for the header-only item.
        let mds = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        XCTAssertEqual(mds.count, 1, "only the complete email lands in the corpus")
    }

    func testRun_partialWithBody_noAnnotation() throws {
        // A partial file that DOES carry the text body the export asked for is
        // not "not downloaded" — no key, normal write (the #274 helper is
        // format-aware; export fetches format "text").
        let out = tempDir()
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(messageId: "<10@x>",
                                         textBody: "real body", fromPartialEmlx: true) },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() })
        XCTAssertEqual(manifest.items[0].status, "written")
        XCTAssertNil(manifest.items[0].bodyDownloaded)
        XCTAssertNil(manifest.items[0].jsonObject["body_downloaded"])
        XCTAssertEqual(manifest.bodyNotDownloaded, 0)
    }

    func testRun_htmlOnlyPartial_notFlaggedNotSkipped() throws {
        // #283 verify (Codex, cross-model): a `.partial.emlx` can carry a FULL
        // html-only body (Mail also uses partial files when attachments are
        // stored externally; an html-only message has no text/plain part).
        // Judging with the fetch format ("text") mis-flagged it — and under
        // skip_partial the complete email would be silently omitted from the
        // corpus forever (the re-fetch loop re-judges and re-skips). The
        // judgment now mirrors the RENDERER's body selection
        // (textBody ?? htmlBody): a body the .md will actually carry is not
        // "missing".
        let out = tempDir()
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(messageId: "<10@x>",
                                         textBody: nil, htmlBody: "<p>full body</p>",
                                         fromPartialEmlx: true) },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() },
            skipPartial: true)
        XCTAssertEqual(manifest.items[0].status, "written",
                       "a partial whose html body IS present must not be skipped")
        XCTAssertNil(manifest.items[0].bodyDownloaded)
        XCTAssertEqual(manifest.bodyNotDownloaded, 0)
    }

    func testPartialBodyMissingForExport_rendererAligned() {
        // Pure-judgment pins: the flag means "the .md body would be empty AND
        // the file was partial" — exactly the renderer's textBody ?? htmlBody
        // selection, including the textBody=="" precedence edge (a non-nil
        // empty text body wins the selection, so the rendered body IS empty
        // even when html content exists).
        XCTAssertTrue(ExportEmailsMarkdown.partialBodyMissingForExport(
            makeEmail(textBody: nil, htmlBody: nil, fromPartialEmlx: true)))
        XCTAssertFalse(ExportEmailsMarkdown.partialBodyMissingForExport(
            makeEmail(textBody: "body", htmlBody: nil, fromPartialEmlx: true)))
        XCTAssertFalse(ExportEmailsMarkdown.partialBodyMissingForExport(
            makeEmail(textBody: nil, htmlBody: "<p>x</p>", fromPartialEmlx: true)))
        XCTAssertTrue(ExportEmailsMarkdown.partialBodyMissingForExport(
            makeEmail(textBody: "", htmlBody: "<p>x</p>", fromPartialEmlx: true)),
            "empty-string textBody wins the renderer selection — the rendered body is empty")
        XCTAssertFalse(ExportEmailsMarkdown.partialBodyMissingForExport(
            makeEmail(textBody: nil, htmlBody: nil, fromPartialEmlx: false)),
            "never flag a non-partial file")
    }

    func testRun_skipPartial_reservesFilenameSlot() throws {
        // #283 verify (Codex): a header_only skip must still consume its
        // filename slot so name attribution is INDEPENDENT of download state.
        // A (partial, skipped) and B (complete) share (date, slug): B must get
        // the -1 suffix (A's base name reserved), so A's later re-export lands
        // on the base name — the same assignment as if both had been complete
        // in one run. Without reservation the attribution flips with timing.
        let out = tempDir()
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10", "11"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { id in
                id == "10"
                    ? self.makeEmail(subject: "Same", messageId: "<10@x>",
                                     textBody: nil, fromPartialEmlx: true)
                    : self.makeEmail(subject: "Same", messageId: "<11@x>")
            },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() },
            skipPartial: true)
        let byId = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.id, $0) })
        XCTAssertEqual(byId["10"]?.status, "header_only")
        XCTAssertNil(byId["10"]?.writtenPath)
        XCTAssertEqual(byId["11"]?.status, "written")
        XCTAssertTrue(byId["11"]?.writtenPath?.hasSuffix("-1.md") == true,
                      "B takes the -1 suffix — the skipped A holds the base slot for its re-export")

        // Second half of the loop (Codex R2 nit): actually re-export A after
        // the "nudge" (body now present) and assert it lands on the BASE name
        // — the same assignment as if both had been complete in run 1.
        let rerun = try ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(subject: "Same", messageId: "<10@x>",
                                         textBody: "downloaded now") },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() },
            skipPartial: true)
        XCTAssertEqual(rerun.items[0].status, "written")
        XCTAssertTrue(rerun.items[0].writtenPath?.hasSuffix("_Same.md") == true,
                      "re-export lands on the reserved base name, not a -N suffix: \(rerun.items[0].writtenPath ?? "nil")")
    }

    func testRun_skipPartial_dedupSkipStillWinsAndUnannotated() throws {
        // Ordering pin: the #177 dedup skip fires BEFORE the partial check — an
        // already-archived email stays status "skipped" (not "header_only")
        // and carries no body_downloaded key even when its fetch result is
        // partial (annotation on a not-to-be-written duplicate is noise).
        let out = tempDir()
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["10"], outputDir: out, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(messageId: "<10@x>",
                                         textBody: nil, fromPartialEmlx: true) },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() },
            skipMessageIds: ["<10@x>"],
            skipPartial: true)
        XCTAssertEqual(manifest.items[0].status, "skipped")
        XCTAssertNil(manifest.items[0].bodyDownloaded)
        XCTAssertEqual(manifest.bodyNotDownloaded, 0)
    }

    // MARK: - #236 ExportDirLock (concurrent-run serialization)

    func testExportDirLock_sequentialAcquireReleaseAcquire_ok() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let first = try ExportDirLock.acquire(outputDir: dir)
        first.release()
        let second = try ExportDirLock.acquire(outputDir: dir)
        second.release()
    }

    func testExportDirLock_contention_failsFastWithBusy() throws {
        // flock is per open-file-description — two separate open()s of the same
        // lockfile conflict even within one process, so contention is testable
        // in-process (mirrors the cross-process concurrent-export case).
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let holder = try ExportDirLock.acquire(outputDir: dir)
        defer { holder.release() }
        XCTAssertThrowsError(try ExportDirLock.acquire(outputDir: dir)) { error in
            guard case ExportDirLockError.busy(let lockedDir) = error else {
                XCTFail("expected .busy, got \(error)"); return
            }
            XCTAssertTrue(lockedDir.contains(dir.lastPathComponent),
                          "busy error must name the contended output_dir: \(lockedDir)")
        }
    }

    func testRun_whileAnotherExportHoldsLock_failsFast_notSilentOverwrite() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let holder = try ExportDirLock.acquire(outputDir: dir)
        defer { holder.release() }
        XCTAssertThrowsError(
            try ExportEmailsMarkdown.run(
                ids: ["1"], outputDir: dir, direction: "received",
                includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
                extraFrontmatter: [],
                fetch: { _ in self.makeEmail() },
                attachmentNamesFor: { _ in [] },
                attachmentData: { _, _ in Data() })
        ) { error in
            guard case ExportDirLockError.busy = error else {
                XCTFail("run under contention must fail fast with .busy, got \(error)"); return
            }
        }
        // fail-fast means NOTHING was written by the losing run
        let written = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertFalse(written.contains { $0.hasSuffix(".md") },
                       "locked-out run must not write any .md: \(written)")
    }

    func testExportDirLock_symlinkAtLockfilePath_refusedNotFollowed() throws {
        // #236 verify (security MEDIUM): a co-resident process planting a
        // symlink at the fixed .export.lock path must not be followed —
        // O_NOFOLLOW parity with every other open in the export write path
        // (#200 discipline). Follow-through would allow out-of-tree file
        // creation and, via a FIFO target, a pre-flock open() hang.
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("innocent-target")
        FileManager.default.createFile(atPath: target.path, contents: Data())
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent(ExportDirLock.lockFileName),
            withDestinationURL: target)
        XCTAssertThrowsError(try ExportDirLock.acquire(outputDir: dir)) { error in
            guard case ExportDirLockError.lockFailed = error else {
                XCTFail("symlinked lockfile must refuse (ELOOP), got \(error)"); return
            }
        }
    }

    func testExportDirLock_fifoAtLockfilePath_failsFastNotHang() throws {
        // With O_NONBLOCK, opening a reader-less FIFO for write returns ENXIO
        // immediately instead of blocking before flock's LOCK_NB is reached —
        // the fail-fast invariant must hold even against a planted FIFO.
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fifoPath = dir.appendingPathComponent(ExportDirLock.lockFileName).path
        guard mkfifo(fifoPath, 0o644) == 0 else {
            throw XCTSkip("mkfifo unavailable in this environment (errno \(errno))")
        }
        let start = Date()
        XCTAssertThrowsError(try ExportDirLock.acquire(outputDir: dir))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0,
                          "FIFO at lockfile path must fail fast, not block")
    }

    func testExportDirLockError_localizedDescription_isActionable() {
        // Server.swift renders tool errors via error.localizedDescription — a
        // bare enum would render as an opaque "(ExportDirLockError error 0)".
        let msg = ExportDirLockError.busy(dir: "/tmp/x").localizedDescription
        XCTAssertTrue(msg.contains("/tmp/x"), msg)
        XCTAssertTrue(msg.contains("retry"), "busy message must tell the caller to retry: \(msg)")
        XCTAssertTrue(msg.contains("#236"), "message should cite the serialization contract: \(msg)")
    }

    func testRun_lockfileHygiene_notSeededNotInManifest_andLockReleased() throws {
        let dir = tempDir()
        // First run writes one email; lockfile is created as a side effect.
        let m1 = try ExportEmailsMarkdown.run(
            ids: ["1"], outputDir: dir, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(messageId: "<a@x>") },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() })
        XCTAssertEqual(m1.written, 1)
        XCTAssertFalse(m1.items.contains { $0.jsonObject.description.contains(ExportDirLock.lockFileName) },
                       "lockfile must never appear as a manifest item")
        // Second sequential run works (lock released) and the dotfile lockfile
        // (not .md) must not perturb the (date,slug) collision seeding.
        let m2 = try ExportEmailsMarkdown.run(
            ids: ["2"], outputDir: dir, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail(subject: "Other", messageId: "<b@x>") },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() })
        XCTAssertEqual(m2.written, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(ExportDirLock.lockFileName).path),
            "lockfile persists between runs by design (unlink would race)")
    }

    func testRun_preExistingLockfile_doesNotPerturbFilenameSeeding() throws {
        // #236 verify (codex): direct assertion that a pre-existing
        // .export.lock in output_dir never counts as a used filename — the
        // exported file must get the BASE name, not a -1 suffix.
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent(ExportDirLock.lockFileName).path,
            contents: Data())
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["1"], outputDir: dir, direction: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:],
            extraFrontmatter: [],
            fetch: { _ in self.makeEmail() },
            attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() })
        let written = try XCTUnwrap(manifest.items.first?.writtenPath)
        XCTAssertTrue(written.hasSuffix("/2026-06-13_Topic.md"),
                      "base name expected — lockfile must not trigger a -N suffix: \(written)")
    }
}
