import Darwin
import MCP
import XCTest
@testable import CheAppleMailMCP

final class ClassificationToolIntegrationTests: XCTestCase {
    private func directory() -> URL {
        let pointer = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(pointer) }
        let path = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private func message() -> ClassificationMessage {
        let source = "Message-ID: <12@example.invalid>\nSubject: fixture\n\nprivate body"
        return .init(id: "12", accountID: "ACCOUNT", mailboxComponents: ["INBOX"], mailboxURL: "imap://ACCOUNT/INBOX",
              messageID: "<12@example.invalid>", sender: "news@example.invalid", subject: "PRIVATE SUBJECT",
              listID: nil, isDraft: false, isFlagged: false, contentDigest: classificationDigest(Data(source.utf8)), nativeSource: source)
    }

    func test_four_tools_are_registered_with_truthful_mutation_hints() throws {
        let tools = CheAppleMailMCPServer.defineTools()
        for name in ["get_email_classification_policy", "configure_email_classification", "classify_emails", "apply_email_classification"] {
            XCTAssertEqual(tools.filter { $0.name == name }.count, 1)
        }
        XCTAssertEqual(tools.first { $0.name == "classify_emails" }?.annotations.readOnlyHint, true)
        XCTAssertEqual(tools.first { $0.name == "apply_email_classification" }?.annotations.destructiveHint, true)
        XCTAssertEqual(tools.first { $0.name == "configure_email_classification" }?.annotations.readOnlyHint, false)
    }

    func test_native_snapshot_uses_same_bytes_and_never_serializes_body() throws {
        let raw = "Message-ID: <id@example.invalid>\r\nFrom: news@example.invalid\r\nSubject: title\r\nList-Id: News <news.example.invalid>\r\n\r\nPRIVATE BODY SENTINEL"
        let metadata: [String: Any] = ["is_draft": false, "flagged": false, "deleted": false]
        let snapshot = try classificationMessageFromNative(id: "12", mailboxURL: "imap://ACCOUNT/INBOX", metadata: metadata,
                                                         nativeSource: raw, retainNativeSource: true)
        XCTAssertEqual(snapshot.contentDigest, classificationDigest(Data(normalizedClassificationSource(raw).utf8)))
        XCTAssertEqual(snapshot.messageID, "<id@example.invalid>")
        XCTAssertEqual(snapshot.nativeSource, normalizedClassificationSource(raw))
        XCTAssertFalse(String(decoding: try classificationCanonicalData(snapshot), as: UTF8.self).contains("PRIVATE BODY SENTINEL"))
        let preview = try classificationMessageFromNative(id: "12", mailboxURL: "imap://ACCOUNT/INBOX", metadata: metadata,
                                                        nativeSource: raw, retainNativeSource: false)
        XCTAssertNil(preview.nativeSource)
        XCTAssertEqual(try preview.fingerprint(), try snapshot.fingerprint())
    }

    func test_actual_server_configure_classify_apply_uses_engine_and_native_seam() async throws {
        let root = directory()
        let msg = message()
        let server = try await CheAppleMailMCPServer(databasePath: root.appendingPathComponent("missing.sqlite").path,
            initialSync: false, classificationDirectory: root, classificationLoader: { _ in msg })
        let policy = ClassificationPolicy(version: 1, categories: [.init(id: "news", label: "電子報")], rules: [
            .init(id: "news", category: "news", conditions: [.init(field: .sender, match: .equals, value: "news@example.invalid")], action: .trash, enabled: true)])
        let value = try JSONDecoder().decode(Value.self, from: policy.canonicalData())
        _ = try await server.executeToolCall(name: "configure_email_classification", arguments: [
            "policy": value, "approve_auto_trash_rule_ids": .array([.string("news")]), "confirm_approval": .bool(true)])
        let raw = try await server.executeToolCall(name: "classify_emails", arguments: ["ids": .array([.string("12")])])
        let plan = try JSONDecoder().decode(ClassificationPlan.self, from: Data(raw.utf8))
        XCTAssertTrue(plan.items[0].automaticTrashAllowed)
        let controller = MailController.shared
        await controller.setTestSeams(scriptRunner: { script in
            XCTAssertTrue(script.contains("move msg to trashBox"))
            return "CLASSIFY_MOVED"
        }, refusal: nil)
        do {
            let resultRaw = try await server.executeToolCall(name: "apply_email_classification", arguments: [
                "plan_id": .string(plan.planID), "ids": .array([.string("12")])])
            let result = try JSONDecoder().decode(ClassificationApplication.self, from: Data(resultRaw.utf8))
            XCTAssertEqual(result.items[0].status, .moved)
            let audit = try String(contentsOf: root.appendingPathComponent("classification-audit.jsonl"), encoding: .utf8)
            XCTAssertFalse(audit.contains(msg.subject))
            XCTAssertTrue(audit.contains("started"))
            XCTAssertTrue(audit.contains("moved"))
            XCTAssertTrue(audit.contains(plan.policyDigest))
            let history = root.appendingPathComponent("classification-policy-history/\(plan.policyDigest).json")
            let saved = try JSONDecoder().decode(ClassificationPolicyEnvelope.self, from: Data(contentsOf: history))
            XCTAssertEqual(try saved.fingerprint(), plan.policyDigest)
            await controller.setTestSeams(scriptRunner: nil, refusal: nil)
        } catch {
            await controller.setTestSeams(scriptRunner: nil, refusal: nil)
            throw error
        }
    }

    func test_invalid_boolean_and_duplicate_ids_are_rejected_by_actual_dispatch() async throws {
        let root = directory()
        let server = try await CheAppleMailMCPServer(databasePath: root.appendingPathComponent("missing.sqlite").path,
            initialSync: false, classificationDirectory: root, classificationLoader: { _ in XCTFail("must not read"); throw CocoaError(.fileReadUnknown) })
        for ids: Value in [.array([.string("12"), .string("12")]), .array([.int(12)]), .array([])] {
            do { _ = try await server.executeToolCall(name: "classify_emails", arguments: ["ids": ids]); XCTFail("invalid ids") }
            catch {}
        }
        do {
            _ = try await server.executeToolCall(name: "apply_email_classification", arguments: [
                "plan_id": .string("plan"), "ids": .array([.string("12")]), "confirmed_preview": .string("true")])
            XCTFail("must not coerce a string to approval")
        } catch {}
    }
}
