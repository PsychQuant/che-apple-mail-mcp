import XCTest
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
}
