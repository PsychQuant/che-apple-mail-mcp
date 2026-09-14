import XCTest
@testable import CheAppleMailMCP

final class EmailClassificationTests: XCTestCase {
    private let category = ClassificationCategory(id: "newsletter", label: "電子報")
    private func rule(id: String = "news", action: ClassificationAction = .trash,
                      value: String = "newsletter@example.invalid") -> ClassificationRule {
        ClassificationRule(id: id, category: category.id,
                           conditions: [.init(field: .sender, match: .equals, value: value)],
                           action: action, enabled: true)
    }
    private func message(sender: String = "News <newsletter@example.invalid>", subject: String = "每週新聞",
                         listID: String? = "News <news.example.invalid>", draft: Bool? = false,
                         flagged: Bool = false, messageID: String = "<m@example.invalid>") -> ClassificationMessage {
        .init(id: "12", accountID: "account-id", mailboxComponents: ["INBOX"],
              mailboxURL: "imap://account-id/INBOX", messageID: messageID, sender: sender,
              subject: subject, listID: listID, isDraft: draft, isFlagged: flagged, contentDigest: String(repeating: "b", count: 64))
    }
    private func policy(_ rules: [ClassificationRule]) throws -> ClassificationPolicy {
        try ClassificationPolicy(version: 1, categories: [category], rules: rules).validated()
    }
    private func approval(_ rule: ClassificationRule) throws -> ClassificationApproval {
        .init(ruleID: rule.id, fingerprint: try rule.fingerprint(), approvedAt: "2026-09-14T00:00:00Z")
    }

    func test_approved_rule_matches_canonical_sender_and_explains_action() throws {
        let p = try policy([rule()])
        let result = try EmailClassifier.classify(message(), policy: p, approvals: [approval(p.rules[0])])
        XCTAssertEqual(result.category, "newsletter")
        XCTAssertEqual(result.action, .trash)
        XCTAssertEqual(result.matchedRules, ["news"])
        XCTAssertTrue(result.automaticTrashAllowed)
        XCTAssertFalse(result.reasons.isEmpty)
        XCTAssertEqual(result.subject, "每週新聞")
        XCTAssertEqual(result.sender, "News <newsletter@example.invalid>")
    }

    func test_unapproved_trash_rule_requires_preview() throws {
        let result = try EmailClassifier.classify(message(), policy: policy([rule()]), approvals: [])
        XCTAssertEqual(result.action, .trash)
        XCTAssertFalse(result.automaticTrashAllowed)
        XCTAssertTrue(result.reasons.contains("rule_not_approved"))
    }

    func test_rule_edits_invalidate_old_approval() throws {
        let old = rule()
        var changed = old
        changed.conditions = [.init(field: .subject, match: .contains, value: "新聞")]
        let result = try EmailClassifier.classify(message(), policy: policy([changed]), approvals: [approval(old)])
        XCTAssertEqual(result.matchedRules, [old.id])
        XCTAssertFalse(result.automaticTrashAllowed)
        XCTAssertNotEqual(try old.fingerprint(), try changed.fingerprint())
    }

    func test_conflicting_rules_do_not_auto_trash() throws {
        let trash = rule()
        let keep = rule(id: "keep", action: .keep)
        let result = try EmailClassifier.classify(message(), policy: policy([trash, keep]), approvals: [approval(trash)])
        XCTAssertEqual(result.category, "conflict")
        XCTAssertEqual(result.action, .review)
        XCTAssertFalse(result.automaticTrashAllowed)
        XCTAssertEqual(Set(result.matchedRules), ["news", "keep"])
    }

    func test_agreeing_rules_allow_only_the_valid_approved_subset() throws {
        let first = rule()
        let second = rule(id: "other")
        let result = try EmailClassifier.classify(message(), policy: policy([first, second]), approvals: [approval(second)])
        XCTAssertTrue(result.automaticTrashAllowed)
        XCTAssertEqual(result.authorizingRules, ["other"])
    }

    func test_draft_unknown_draft_flagged_and_missing_identity_stay_preview() throws {
        let p = try policy([rule()])
        for m in [message(draft: true), message(draft: nil), message(flagged: true), message(messageID: "")] {
            let result = try EmailClassifier.classify(m, policy: p, approvals: [approval(p.rules[0])])
            XCTAssertEqual(result.category, category.id)
            XCTAssertFalse(result.automaticTrashAllowed)
        }
    }

    func test_no_match_and_disabled_rule_are_unclassified() throws {
        var disabled = rule()
        disabled.enabled = false
        for p in [try policy([disabled]), try policy([rule(value: "other@example.invalid")]), .empty] {
            let result = try EmailClassifier.classify(message(), policy: p, approvals: [])
            XCTAssertEqual(result.category, "unclassified")
            XCTAssertEqual(result.action, .review)
            XCTAssertFalse(result.automaticTrashAllowed)
        }
    }

    func test_subject_and_list_id_use_all_conditions() throws {
        var r = rule()
        r.conditions = [.init(field: .subject, match: .contains, value: "新聞"),
                        .init(field: .listID, match: .equals, value: "news.example.invalid")]
        let p = try policy([r])
        XCTAssertEqual(try EmailClassifier.classify(message(), policy: p, approvals: []).category, category.id)
        XCTAssertEqual(try EmailClassifier.classify(message(listID: "other.example.invalid"), policy: p, approvals: []).category, "unclassified")
        XCTAssertEqual(try EmailClassifier.classify(message(subject: "私人往來"), policy: p, approvals: []).category, "unclassified")
    }

    func test_contains_sender_and_empty_rules_or_unknown_categories_are_rejected() throws {
        var r = rule()
        r.conditions[0].match = .contains
        XCTAssertThrowsError(try policy([r]))
        r = rule(); r.conditions = []
        XCTAssertThrowsError(try policy([r]))
        r = rule(); r.category = "missing"
        XCTAssertThrowsError(try policy([r]))
        XCTAssertThrowsError(try policy([rule(), rule()]))
        r = rule(); r.conditions[0].value = ""
        XCTAssertThrowsError(try policy([r]))
    }

    func test_json_unknown_fields_and_body_conditions_are_rejected() throws {
        let p = try policy([rule()])
        let data = try p.canonicalData()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["body"] = "private content must not be accepted"
        XCTAssertThrowsError(try ClassificationPolicy.decode(JSONSerialization.data(withJSONObject: object)))
        object.removeValue(forKey: "body")
        var rules = try XCTUnwrap(object["rules"] as? [[String: Any]])
        rules[0]["conditions"] = [["field": "body", "match": "contains", "value": "secret"]]
        object["rules"] = rules
        XCTAssertThrowsError(try ClassificationPolicy.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(try ClassificationPolicy.decode(data), p)
    }

    func test_list_id_and_sender_spoofing_do_not_expand_matching() throws {
        XCTAssertEqual(EmailClassifier.canonicalListID("Display <LIST.EXAMPLE.INVALID>"), "list.example.invalid")
        XCTAssertNil(EmailClassifier.canonicalListID("Display <list.example.invalid> suffix"))
        let p = try policy([rule()])
        let result = try EmailClassifier.classify(message(sender: "newsletter@example.invalid <attacker@example.invalid>"), policy: p, approvals: [])
        XCTAssertEqual(result.category, "unclassified")
    }

    func test_control_characters_and_non_message_ids_are_not_verifiable() {
        XCTAssertFalse(message(messageID: "<bad\u{0}id@example.invalid>").hasVerifiableIdentity)
        XCTAssertFalse(message(messageID: "<not-an-id>").hasVerifiableIdentity)
        var invalid = message()
        invalid.accountID = "account\nother"
        XCTAssertFalse(invalid.hasVerifiableIdentity)
        invalid = message()
        invalid.mailboxComponents = ["INBOX\r"]
        XCTAssertFalse(invalid.hasVerifiableIdentity)
    }

    func test_malformed_message_id_atom_forms_stay_preview() {
        for value in ["<a@b@c>", "<a..b@example.invalid>", "<a@.example.invalid>", "<a(b)@example.invalid>",
                      "<a@domain.>", "<a\\b@example.invalid>"] {
            XCTAssertFalse(message(messageID: value).hasVerifiableIdentity, value)
        }
    }

    func test_message_fingerprint_changes_with_classification_inputs() throws {
        XCTAssertNotEqual(try message().fingerprint(), try message(subject: "changed").fingerprint())
        XCTAssertNotEqual(try message().fingerprint(), try message(draft: true).fingerprint())
        XCTAssertEqual(try message().fingerprint(), try message().fingerprint())
        var changedBody = message()
        changedBody.contentDigest = String(repeating: "c", count: 64)
        XCTAssertNotEqual(try message().fingerprint(), try changedBody.fingerprint())
        changedBody.contentDigest = ""
        XCTAssertFalse(changedBody.hasVerifiableIdentity)
    }
}
