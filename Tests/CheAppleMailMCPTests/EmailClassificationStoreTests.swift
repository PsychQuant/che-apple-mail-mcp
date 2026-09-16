import XCTest
import Darwin
@testable import CheAppleMailMCP

final class EmailClassificationStoreTests: XCTestCase {
    private func directory() -> URL {
        let pointer = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(pointer) }
        let path = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent("classification-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private func policy(subject: String = "電子報") -> ClassificationPolicy {
        .init(version: 1, categories: [.init(id: "news", label: "電子報")], rules: [
            .init(id: "news-rule", category: "news", conditions: [.init(field: .subject, match: .contains, value: subject)],
                  action: .trash, enabled: true)])
    }

    func test_missing_policy_is_empty_without_creating_preferences() throws {
        let root = directory()
        let store = ClassificationPolicyStore(directory: root)
        XCTAssertEqual(try store.load().policy, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func test_approval_requires_explicit_confirmation_and_bound_rule() throws {
        let root = directory()
        let store = ClassificationPolicyStore(directory: root)
        XCTAssertThrowsError(try store.configure(policy(), approving: ["news-rule"], confirmed: false))
        XCTAssertEqual(try store.load().policy, .empty)
        let stored = try store.configure(policy(), approving: ["news-rule"], confirmed: true)
        XCTAssertEqual(stored.approvals.map(\.ruleID), ["news-rule"])
        XCTAssertEqual(stored.approvals[0].fingerprint, try stored.policy.rules[0].fingerprint())
        XCTAssertEqual(try store.load(), stored)
    }

    func test_edit_prunes_approval_and_revoke_changes_envelope_digest() throws {
        let store = ClassificationPolicyStore(directory: directory())
        let first = try store.configure(policy(), approving: ["news-rule"], confirmed: true)
        let kept = try store.configure(policy())
        XCTAssertEqual(kept.approvals, first.approvals)
        let revoked = try store.configure(policy(), revoking: ["news-rule"])
        XCTAssertTrue(revoked.approvals.isEmpty)
        XCTAssertNotEqual(try revoked.fingerprint(), try first.fingerprint(), "plan version must include approvals")
        _ = try store.configure(policy(), approving: ["news-rule"], confirmed: true)
        XCTAssertTrue(try store.configure(policy(subject: "新規則")).approvals.isEmpty)
    }

    func test_invalid_approval_does_not_replace_existing_policy() throws {
        let store = ClassificationPolicyStore(directory: directory())
        let before = try store.configure(policy())
        XCTAssertThrowsError(try store.configure(policy(subject: "changed"), approving: ["missing"], confirmed: true))
        XCTAssertEqual(try store.load(), before)
        var disabled = policy()
        disabled.rules[0].enabled = false
        XCTAssertThrowsError(try store.configure(disabled, approving: ["news-rule"], confirmed: true))
        XCTAssertEqual(try store.load(), before)
    }

    func test_policy_is_owner_only_and_unsafe_file_is_rejected() throws {
        let root = directory()
        let store = ClassificationPolicyStore(directory: root)
        _ = try store.configure(policy())
        let file = root.appendingPathComponent("classification-policy.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        XCTAssertThrowsError(try store.load())
    }

    func test_policy_symlink_never_reads_or_overwrites_its_target() throws {
        let root = directory()
        let store = ClassificationPolicyStore(directory: root)
        _ = try store.configure(policy())
        let outside = root.appendingPathComponent("outside.json")
        try Data("keep".utf8).write(to: outside)
        let policyFile = root.appendingPathComponent("classification-policy.json")
        try FileManager.default.removeItem(at: policyFile)
        try FileManager.default.createSymbolicLink(at: policyFile, withDestinationURL: outside)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.configure(policy()))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }

    func test_audit_contains_identifiers_and_hash_only() throws {
        let root = directory()
        let store = ClassificationPolicyStore(directory: root)
        let event = ClassificationAuditEvent(timestamp: "2026-09-14T00:00:00Z", planID: UUID().uuidString,
                                             itemID: "12", messageIDDigest: String(repeating: "a", count: 64),
                                             ruleIDs: ["news-rule"], category: "news", outcome: .started)
        try store.appendAudit(event)
        let data = try Data(contentsOf: root.appendingPathComponent("classification-audit.jsonl"))
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(row["subject"])
        XCTAssertNil(row["body"])
        XCTAssertNil(row["message_id"])
        XCTAssertEqual(row["message_id_digest"] as? String, String(repeating: "a", count: 64))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasSuffix("\n"))
    }

    func test_audit_symlink_is_refused() throws {
        let root = directory()
        let store = ClassificationPolicyStore(directory: root)
        _ = try store.configure(policy())
        let outside = root.appendingPathComponent("outside-audit")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("classification-audit.jsonl"), withDestinationURL: outside)
        let event = ClassificationAuditEvent(timestamp: "2026-09-14T00:00:00Z", planID: UUID().uuidString,
                                             itemID: "12", messageIDDigest: String(repeating: "a", count: 64),
                                             ruleIDs: [], category: "unclassified", outcome: .started)
        XCTAssertThrowsError(try store.appendAudit(event))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }
    func test_audit_partial_tail_is_not_silently_extended() throws {
        let root = directory()
        let store = ClassificationPolicyStore(directory: root)
        _ = try store.configure(policy())
        let file = root.appendingPathComponent("classification-audit.jsonl")
        try Data("partial".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let event = ClassificationAuditEvent(timestamp: "2026-09-14T00:00:00Z", planID: UUID().uuidString,
                                             itemID: "12", messageIDDigest: String(repeating: "a", count: 64),
                                             ruleIDs: [], category: "unclassified", outcome: .started)
        XCTAssertThrowsError(try store.appendAudit(event))
        XCTAssertEqual(try Data(contentsOf: file), Data("partial".utf8))
    }

    func test_policy_hard_link_is_not_accepted() throws {
        let root = directory()
        let store = ClassificationPolicyStore(directory: root)
        _ = try store.configure(policy())
        try FileManager.default.linkItem(at: root.appendingPathComponent("classification-policy.json"),
                                         to: root.appendingPathComponent("other-name.json"))
        XCTAssertThrowsError(try store.load())
    }

    func test_ancestor_symlink_neither_loads_approvals_nor_creates_external_preferences() throws {
        let root = directory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let redirected = ClassificationPolicyStore(directory: alias.appendingPathComponent(".mail"))
        XCTAssertThrowsError(try redirected.configure(policy()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent(".mail").path))
        let real = ClassificationPolicyStore(directory: outside.appendingPathComponent(".mail"))
        _ = try real.configure(policy(), approving: ["news-rule"], confirmed: true)
        XCTAssertThrowsError(try redirected.load())
    }

}
