import Darwin
import MCP
import MailSQLite
import XCTest
@testable import CheAppleMailMCP


private final class ClassificationVIPSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private let unavailableAtBoundary: Bool
    init(unavailableAtBoundary: Bool = false) { self.unavailableAtBoundary = unavailableAtBoundary }
    func snapshot() -> VIPSenderSnapshot {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        if reads >= 3 && unavailableAtBoundary { return .unavailable }
        let records: [[String: Any]] = reads < 3 ? [] : [["Addresses": ["news@example.invalid"]]]
        let data = try! PropertyListSerialization.data(fromPropertyList: records, format: .xml, options: 0)
        return .parse(data)
    }
}

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
            initialSync: false, classificationDirectory: root, classificationLoader: { _ in msg },
            classificationVIPLoader: { VIPSenderSnapshot.parse(Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><array/></plist>".utf8)) })
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

    private func approvedServer(root: URL, vip: @escaping @Sendable () -> VIPSenderSnapshot) async throws -> CheAppleMailMCPServer {
        let msg = message()
        let server = try await CheAppleMailMCPServer(databasePath: root.appendingPathComponent("missing.sqlite").path,
            initialSync: false, classificationDirectory: root, classificationLoader: { _ in msg }, classificationVIPLoader: vip)
        let policy = ClassificationPolicy(version: 1, categories: [.init(id: "news", label: "News")], rules: [
            .init(id: "news", category: "news", conditions: [.init(field: .sender, match: .equals, value: "news@example.invalid")], action: .trash, enabled: true)])
        _ = try await server.executeToolCall(name: "configure_email_classification", arguments: [
            "policy": JSONDecoder().decode(Value.self, from: policy.canonicalData()),
            "approve_auto_trash_rule_ids": .array([.string("news")]), "confirm_approval": .bool(true)])
        return server
    }

    private func classify(_ server: CheAppleMailMCPServer) async throws -> ClassificationPlan {
        let raw = try await server.executeToolCall(name: "classify_emails", arguments: ["ids": .array([.string("12")])])
        return try JSONDecoder().decode(ClassificationPlan.self, from: Data(raw.utf8))
    }

    func test_server_vip_unknown_and_expired_lookup_require_preview() async throws {
        let vipData = try PropertyListSerialization.data(fromPropertyList: [["Addresses": ["NEWS@EXAMPLE.INVALID"]]], format: .binary, options: 0)
        for mode in ["vip", "unavailable", "expired"] {
            let root = directory()
            let server = try await approvedServer(root: root, vip: {
                if mode == "unavailable" { return .unavailable }
                return .parse(vipData, observedAt: mode == "expired" ? Date().addingTimeInterval(-60) : Date())
            })
            let plan = try await classify(server)
            XCTAssertFalse(plan.items[0].automaticTrashAllowed)
            XCTAssertTrue(plan.items[0].reasons.contains(mode == "vip" ? "vip_protected" : "vip_status_unknown"))
            do {
                _ = try await server.executeToolCall(name: "apply_email_classification", arguments: [
                    "plan_id": .string(plan.planID), "ids": .array([.string("12")])])
                XCTFail("rule approval alone cannot authorize protected mail")
            } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("classification-audit.jsonl").path))
        }
    }

    func test_server_rereads_vip_file_after_preview_and_refuses_changes() async throws {
        for corrupt in [false, true] {
            for confirmed in [false, true] {
                let root = directory(), vipRoot = directory()
                try FileManager.default.createDirectory(at: vipRoot, withIntermediateDirectories: true)
                let url = vipRoot.appendingPathComponent("VIPMailboxes.plist")
                let empty = try PropertyListSerialization.data(fromPropertyList: [], format: .xml, options: 0)
                try empty.write(to: url)
                // This injected fixture is known to be a complete sender list.
                // Production read() cannot assert completeness of Mail's private file.
                let server = try await approvedServer(root: root, vip: {
                    guard let data = try? Data(contentsOf: url) else { return .unavailable }
                    return .parse(data)
                })
                let plan = try await classify(server)
                XCTAssertTrue(plan.items[0].automaticTrashAllowed)
                let changed: Data
                if corrupt { changed = Data("invalid".utf8) }
                else {
                    changed = try PropertyListSerialization.data(
                        fromPropertyList: [["Addresses": ["news@example.invalid"]]], format: .xml, options: 0)
                }
                try changed.write(to: url, options: .atomic)
                let raw = try await server.executeToolCall(name: "apply_email_classification", arguments: [
                    "plan_id": .string(plan.planID), "ids": .array([.string("12")]), "confirmed_preview": .bool(confirmed)])
                let result = try JSONDecoder().decode(ClassificationApplication.self, from: Data(raw.utf8))
                XCTAssertEqual(result.items[0].status, .notAttempted)
                XCTAssertEqual(result.items[0].reason, "message_changed")
                XCTAssertFalse(result.items[0].auditRecorded)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("classification-audit.jsonl").path))
            }
        }
    }

    func test_native_boundary_rechecks_vip_after_refresh_before_script_dispatch() async throws {
        for unknown in [false, true] {
            let root = directory(), sequence = ClassificationVIPSequence(unavailableAtBoundary: unknown)
            let server = try await approvedServer(root: root, vip: { sequence.snapshot() })
            let plan = try await classify(server)
            XCTAssertTrue(plan.items[0].automaticTrashAllowed)
            let controller = MailController.shared
            await controller.setTestSeams(scriptRunner: { _ in XCTFail("VIP changed at native boundary"); return "CLASSIFY_MOVED" }, refusal: nil)
            do {
                let raw = try await server.executeToolCall(name: "apply_email_classification", arguments: [
                    "plan_id": .string(plan.planID), "ids": .array([.string("12")])])
                let result = try JSONDecoder().decode(ClassificationApplication.self, from: Data(raw.utf8))
                XCTAssertEqual(result.items[0].status, .refused)
                XCTAssertEqual(result.items[0].reason, "native_guard_refused")
                XCTAssertTrue(result.items[0].auditRecorded)
                let audit = try String(contentsOf: root.appendingPathComponent("classification-audit.jsonl"))
                XCTAssertTrue(audit.contains("started"))
                XCTAssertTrue(audit.contains("refused"))
                let fresh = try await classify(server)
                XCTAssertFalse(fresh.items[0].automaticTrashAllowed)
                XCTAssertTrue(fresh.items[0].reasons.contains(unknown ? "vip_status_unknown" : "vip_protected"))
                await controller.setTestSeams(scriptRunner: nil, refusal: nil)
            } catch {
                await controller.setTestSeams(scriptRunner: nil, refusal: nil)
                throw error
            }
        }
    }

    func test_actual_server_explicit_confirmation_can_move_stable_vip_or_unknown() async throws {
        let vipData = try PropertyListSerialization.data(fromPropertyList: [["Addresses": ["news@example.invalid"]]], format: .xml, options: 0)
        for unknown in [false, true] {
            let root = directory()
            let server = try await approvedServer(root: root, vip: { unknown ? .unavailable : .parse(vipData) })
            let plan = try await classify(server)
            XCTAssertFalse(plan.items[0].automaticTrashAllowed)
            let controller = MailController.shared
            await controller.setTestSeams(scriptRunner: { _ in "CLASSIFY_MOVED" }, refusal: nil)
            do {
                let raw = try await server.executeToolCall(name: "apply_email_classification", arguments: [
                    "plan_id": .string(plan.planID), "ids": .array([.string("12")]), "confirmed_preview": .bool(true)])
                let result = try JSONDecoder().decode(ClassificationApplication.self, from: Data(raw.utf8))
                XCTAssertEqual(result.items[0].status, .moved)
                XCTAssertTrue(result.items[0].auditRecorded)
                await controller.setTestSeams(scriptRunner: nil, refusal: nil)
            } catch {
                await controller.setTestSeams(scriptRunner: nil, refusal: nil)
                throw error
            }
        }
    }

    func test_production_reader_empty_mail_file_does_not_authorize_automatic_trash() async throws {
        let root = directory(), vipRoot = directory()
        try FileManager.default.createDirectory(at: vipRoot, withIntermediateDirectories: true)
        let url = vipRoot.appendingPathComponent("VIPMailboxes.plist")
        try PropertyListSerialization.data(fromPropertyList: [], format: .xml, options: 0).write(to: url)
        let server = try await approvedServer(root: root, vip: { .read(from: url) })
        let plan = try await classify(server)
        XCTAssertFalse(plan.items[0].automaticTrashAllowed)
        XCTAssertTrue(plan.items[0].reasons.contains("vip_status_unknown"))
    }
}
