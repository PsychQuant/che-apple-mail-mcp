import XCTest
@testable import CheAppleMailMCP

final class DraftStatusFallbackTests: XCTestCase {
    func testListFallbackDisclosesUnknownWithOneExistingCall() async throws {
        var scripts: [String] = []
        await MailController.shared.setTestSeams(scriptRunner: {
            scripts.append($0)
            return "1\u{001E}fixture\u{001E}sender@example.test"
        }, refusal: { nil })
        do {
            let rows = try await MailController.shared.listEmails(mailbox: "Drafts", accountName: "Fixture")
            XCTAssertEqual(rows.count, 1)
            XCTAssertTrue(rows[0]["is_draft"] is NSNull)
            XCTAssertEqual(scripts.count, 1)
            XCTAssertFalse(scripts[0].contains("all headers"))
        } catch {
            await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
            throw error
        }
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
    }

    func testSearchFallbackDisclosesUnknownWithoutExtraHeaderCalls() async throws {
        var scripts: [String] = []
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: { nil }, scriptListRunner: {
            scripts.append($0)
            return ["1⏐fixture⏐sender@example.test⏐date⏐Fixture⏐All Mail"]
        })
        do {
            let rows = try await MailController.shared.searchEmails(query: "fixture", field: .subject)
            XCTAssertEqual(rows.count, 1)
            XCTAssertTrue(rows[0]["is_draft"] is NSNull)
            XCTAssertEqual(scripts.count, 1)
            XCTAssertFalse(scripts[0].contains("all headers"))
        } catch {
            await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
            throw error
        }
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
    }

    func testMetadataFallbackDisclosesUnknownWithExistingCallCount() async throws {
        var scripts: [String] = []
        await MailController.shared.setTestSeams(scriptRunner: { scripts.append($0); return "false" }, refusal: { nil })
        do {
            let metadata = try await MailController.shared.getEmailMetadata(id: "1", mailbox: "Drafts", accountName: "Fixture")
            XCTAssertTrue(metadata["is_draft"] is NSNull)
            XCTAssertEqual(scripts.count, 5)
            XCTAssertFalse(scripts.contains { $0.contains("all headers") })
        } catch {
            await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
            throw error
        }
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
    }
}
