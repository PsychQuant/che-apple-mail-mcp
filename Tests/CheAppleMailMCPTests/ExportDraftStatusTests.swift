import XCTest
import MCP
@testable import CheAppleMailMCP
@testable import MailSQLite

final class ExportDraftStatusTests: XCTestCase {
    private func content(_ id: String) -> EmailContent {
        EmailContent(subject: "Fixture " + id, sender: "sender@example.test", toRecipients: [], ccRecipients: [],
                     date: "Tue, 30 Jun 2026 12:00:00 +0000", messageId: "<\(id)@fixture.test>", inReplyTo: "",
                     textBody: "body", htmlBody: nil, rawSource: nil, fromPartialEmlx: false)
    }
    private func directory() -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("export374-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }

    func testStrictExportRejectsDraftAndUnknownBeforeContentFetch() throws {
        var fetched: [String] = [], attachments: [String] = []
        let root = directory()
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["draft", "real", "unknown", "failure"], outputDir: root, ownAddresses: [],
            fallbackDirection: "received", includeAttachments: true, filenameTemplate: nil,
            filenameOverrides: [:], extraFrontmatter: [],
            fetch: { fetched.append($0); return self.content($0) },
            attachmentNamesFor: { attachments.append($0); return [] },
            attachmentData: { _, _ in XCTFail("no attachments in fixture"); return Data() },
            skipDrafts: true, draftStatusFor: {
                switch $0 {
                case "draft": return true
                case "real": return false
                case "failure": throw NSError(domain: "fixture", code: 1)
                default: return nil
                }
            })
        XCTAssertEqual(fetched, ["real"])
        XCTAssertEqual(attachments, ["real"])
        XCTAssertEqual(manifest.written, 1)
        // Draft exclusions have their own status and count, so `skipped` keeps
        // meaning "already archived" for readers of the dedup (#374 verify).
        XCTAssertEqual(manifest.skipped, 0)
        XCTAssertEqual(manifest.draftsSkipped, 1)
        XCTAssertEqual(manifest.jsonObject["drafts_skipped"] as? Int, 1)
        XCTAssertEqual(manifest.errors, 2)
        XCTAssertEqual(manifest.items[0].status, "draft_skipped")
        XCTAssertEqual(manifest.items[0].skipReason, "draft")
        XCTAssertEqual(manifest.items[0].jsonObject["is_draft"] as? Bool, true)
        XCTAssertEqual(manifest.items[1].jsonObject["is_draft"] as? Bool, false)
        for item in manifest.items.suffix(2) {
            XCTAssertTrue(item.jsonObject["is_draft"] is NSNull)
            XCTAssertTrue(item.error?.contains("draft_status_unknown") == true)
            XCTAssertNil(item.writtenPath)
        }
        XCTAssertTrue(manifest.items[3].error?.contains("lookup failed:") == true,
                      "a failed lookup names its cause instead of only 'unknown'")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }.count, 1)
    }

    func testDefaultExportStillWritesAndDisclosesUnknown() throws {
        var fetched: [String] = []
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["draft", "unknown"], outputDir: directory(), ownAddresses: [], fallbackDirection: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:], extraFrontmatter: [],
            fetch: { fetched.append($0); return self.content($0) }, attachmentNamesFor: { _ in [] },
            attachmentData: { _, _ in Data() }, draftStatusFor: { $0 == "draft" ? true : nil })
        XCTAssertEqual(manifest.written, 2)
        XCTAssertEqual(fetched, ["draft", "unknown"])
        XCTAssertEqual(manifest.items[0].isDraft, true)
        XCTAssertTrue(manifest.items[1].jsonObject["is_draft"] is NSNull)
    }

    func testRepeatedIDRetainsEachObservedStatus() throws {
        var calls = 0
        let manifest = try ExportEmailsMarkdown.run(
            ids: ["same", "same"], outputDir: directory(), ownAddresses: [], fallbackDirection: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:], extraFrontmatter: [],
            fetch: { self.content($0) }, attachmentNamesFor: { _ in [] }, attachmentData: { _, _ in Data() },
            draftStatusFor: { _ in calls += 1; return calls == 1 })
        XCTAssertEqual(manifest.items.map { $0.isDraft }, [true, false])
    }

    func testSkipDraftOptionRequiresActualBoolean() throws {
        XCTAssertFalse(try parseSkipDraftsOption(nil))
        XCTAssertFalse(try parseSkipDraftsOption(.bool(false)))
        XCTAssertTrue(try parseSkipDraftsOption(.bool(true)))
        for value: Value in [.null, .string("true"), .int(1), .object([:]), .array([])] {
            XCTAssertThrowsError(try parseSkipDraftsOption(value))
        }
    }

    /// skip_drafts outside opts and a non-object opts are rejected; an explicit
    /// null opts means absent (#374 verify).
    func testExportOptionsRejectMisplacedFlagAndNonObjectOpts() throws {
        XCTAssertThrowsError(try CheAppleMailMCPServer.exportOptions(from: ["skip_drafts": .bool(true)]))
        for opts: Value in [.bool(true), .string("x"), .array([])] {
            XCTAssertThrowsError(try CheAppleMailMCPServer.exportOptions(from: ["opts": opts]), "\(opts)")
        }
        XCTAssertEqual(try CheAppleMailMCPServer.exportOptions(from: ["opts": .null]), [:])
        XCTAssertEqual(try CheAppleMailMCPServer.exportOptions(from: [:]), [:])
        XCTAssertEqual(try CheAppleMailMCPServer.exportOptions(from: ["opts": .object(["skip_drafts": .bool(true)])]),
                       ["skip_drafts": .bool(true)])
    }

    func testSearchJSONPreservesTrueFalseAndNull() {
        for flag: Bool? in [true, false, nil] {
            let result = SearchResult(id: 1, subject: "fixture", senderAddress: "a@example.test", senderName: "A",
                                      dateReceived: Date(timeIntervalSince1970: 0), accountName: "Fixture",
                                      mailboxPath: "All Mail", isRead: true, isFlagged: false, toRecipients: [], isDraft: flag)
            let summary = CheAppleMailMCPServer.formatSummaryResultForJSON(result)
            XCTAssertEqual(Set(summary.keys), ["id", "date", "sender", "subject", "mailbox", "is_draft"])
            for json in [CheAppleMailMCPServer.formatSearchResultForJSON(result), summary] {
                if let flag { XCTAssertEqual(json["is_draft"] as? Bool, flag) }
                else { XCTAssertTrue(json["is_draft"] is NSNull) }
                XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
            }
        }
    }
}
