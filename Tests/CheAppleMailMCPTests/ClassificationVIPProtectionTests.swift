import Darwin
import XCTest
import MailSQLite
@testable import CheAppleMailMCP

final class ClassificationVIPProtectionTests: XCTestCase {
    private func message(vip: Bool?) throws -> ClassificationMessage {
        // Decode the wire field so this regression also runs against the
        // pre-fix model, which silently ignores is_vip.
        let object: [String: Any] = [
            "id": "12", "account_id": "ACCOUNT", "mailbox_components": ["INBOX"],
            "mailbox_url": "imap://ACCOUNT/INBOX", "message_id": "<12@example.invalid>",
            "sender": "News <news@example.invalid>", "subject": "newsletter",
            "is_draft": false, "is_flagged": false, "is_vip": vip.map { $0 as Any } ?? NSNull(),
            "content_digest": String(repeating: "a", count: 64)
        ]
        return try JSONDecoder().decode(ClassificationMessage.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func decision(_ message: ClassificationMessage) throws -> ClassificationDecision {
        let rule = ClassificationRule(id: "news", category: "news",
            conditions: [.init(field: .sender, match: .equals, value: "news@example.invalid")],
            action: .trash, enabled: true)
        let policy = ClassificationPolicy(version: 1, categories: [.init(id: "news", label: "News")], rules: [rule])
        return try EmailClassifier.classify(message, policy: policy, approvals: [
            .init(ruleID: "news", fingerprint: rule.fingerprint(), approvedAt: "2026-10-29T00:00:00Z")])
    }

    func test_vip_with_approved_rule_stays_in_preview() throws {
        let result = try decision(message(vip: true))
        XCTAssertEqual(result.action, .trash)
        XCTAssertEqual(result.authorizingRules, ["news"])
        XCTAssertFalse(result.automaticTrashAllowed)
        XCTAssertTrue(result.reasons.contains("vip_protected"))
    }

    func test_unknown_vip_status_with_approved_rule_stays_in_preview() throws {
        let result = try decision(message(vip: nil))
        XCTAssertFalse(result.automaticTrashAllowed)
        XCTAssertTrue(result.reasons.contains("vip_status_unknown"))
    }

    func test_known_non_vip_with_approved_rule_can_auto_trash() throws {
        XCTAssertTrue(try decision(message(vip: false)).automaticTrashAllowed)
    }

    func test_vip_status_changes_invalidate_message_fingerprint() throws {
        XCTAssertNotEqual(try message(vip: false).fingerprint(), try message(vip: true).fingerprint())
        XCTAssertNotEqual(try message(vip: false).fingerprint(), try message(vip: nil).fingerprint())
    }

    func test_broad_subject_rule_cannot_bypass_vip_with_quoted_local_part() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [["Addresses": ["news@example.invalid"]]], format: .xml, options: 0)
        var msg = try message(vip: false)
        msg.sender = "\"news\"@example.invalid"
        msg.isVIP = VIPSenderSnapshot.parse(data).status(for: msg.sender)
        let rule = ClassificationRule(id: "broad", category: "news",
            conditions: [.init(field: .subject, match: .contains, value: "news")], action: .trash, enabled: true)
        let result = try EmailClassifier.classify(msg,
            policy: .init(version: 1, categories: [.init(id: "news", label: "News")], rules: [rule]),
            approvals: [.init(ruleID: "broad", fingerprint: rule.fingerprint(), approvedAt: "2026-10-29T00:00:00Z")])
        XCTAssertEqual(result.action, .trash)
        XCTAssertFalse(result.automaticTrashAllowed)
        XCTAssertTrue(result.reasons.contains("vip_status_unknown"))
    }

    private func engine() throws -> (ClassificationPlanEngine, ClassificationPolicyStore) {
        let pointer = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(pointer) }
        let root = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ClassificationPolicyStore(directory: root)
        let rule = ClassificationRule(id: "news", category: "news",
            conditions: [.init(field: .sender, match: .equals, value: "news@example.invalid")], action: .trash, enabled: true)
        _ = try store.configure(.init(version: 1, categories: [.init(id: "news", label: "News")], rules: [rule]), approving: ["news"], confirmed: true)
        return (.init(store: store), store)
    }

    func test_vip_and_unknown_cannot_apply_without_explicit_preview() async throws {
        for vip: Bool? in [true, nil] {
            let (engine, store) = try engine()
            let msg = try message(vip: vip)
            let plan = try await engine.makePlan(messages: [msg])
            do {
                _ = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: false,
                    refresh: { _ in XCTFail("selection must reject before refresh"); return msg },
                    move: { _, _, _ in XCTFail("must not move protected mail"); return .moved })
                XCTFail("must require preview confirmation")
            } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("classification-audit.jsonl").path))
        }
    }

    func test_status_change_after_preview_refuses_even_with_confirmation() async throws {
        for vip: Bool? in [true, nil] {
            for confirmed in [false, true] {
                let (engine, store) = try engine()
                let msg = try message(vip: false), updated = try message(vip: vip)
                let plan = try await engine.makePlan(messages: [msg])
                let result = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: confirmed,
                    refresh: { _ in updated }, move: { _, _, _ in XCTFail("stale protection state"); return .moved })
                XCTAssertEqual(result.items[0].status, .notAttempted)
                XCTAssertEqual(result.items[0].reason, "message_changed")
                XCTAssertFalse(result.items[0].auditRecorded)
                XCTAssertFalse(try store.dispatchBlocked(updated))
            }
        }
    }

    func test_confirmed_vip_preserves_audit_and_cross_plan_duplicate_block() async throws {
        let (engine, store) = try engine()
        let msg = try message(vip: true)
        let plan = try await engine.makePlan(messages: [msg])
        let result = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: true,
            refresh: { _ in msg }, move: { _, _, _ in
                let audit = try String(contentsOf: store.directory.appendingPathComponent("classification-audit.jsonl"))
                XCTAssertTrue(audit.contains("started"))
                XCTAssertFalse(audit.contains("News <news@example.invalid>"))
                return .moved
            })
        XCTAssertEqual(result.items[0].status, .moved)
        let second = try await engine.makePlan(messages: [msg])
        let retry = try await engine.apply(planID: second.planID, ids: [msg.id], confirmed: true,
            refresh: { _ in msg }, move: { _, _, _ in XCTFail("must not retry"); return .moved })
        XCTAssertEqual(retry.items[0].reason, "identity_already_attempted")
    }

    func test_rule_edit_invalidates_vip_preview_even_if_reapproved() async throws {
        let (engine, store) = try engine()
        let msg = try message(vip: true)
        let plan = try await engine.makePlan(messages: [msg])
        var policy = try store.load().policy
        policy.rules[0].conditions = [.init(field: .subject, match: .contains, value: "news")]
        _ = try await engine.configure(policy, approving: ["news"], confirmed: true)
        do {
            _ = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: true,
                refresh: { _ in msg }, move: { _, _, _ in XCTFail("policy changed"); return .moved })
            XCTFail("stale policy")
        } catch {}
        let fresh = try await engine.makePlan(messages: [msg])
        XCTAssertFalse(fresh.items[0].automaticTrashAllowed)
        XCTAssertTrue(fresh.items[0].reasons.contains("vip_protected"))
    }

    func test_non_vip_does_not_bypass_draft_unknown_draft_or_flagged_protection() throws {
        for reason in ["draft_protected", "draft_status_unknown", "flagged_protected"] {
            var msg = try message(vip: false)
            if reason == "flagged_protected" { msg.isFlagged = true }
            else { msg.isDraft = reason == "draft_protected" ? true : nil }
            let result = try decision(msg)
            XCTAssertFalse(result.automaticTrashAllowed)
            XCTAssertTrue(result.reasons.contains(reason))
        }
    }
}
