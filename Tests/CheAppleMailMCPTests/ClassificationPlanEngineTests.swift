import Darwin
import XCTest
@testable import CheAppleMailMCP

private final class ClassificationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
}
private actor ClassificationCalls {
    var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}

final class ClassificationPlanEngineTests: XCTestCase {
    private func setup(approved: Bool = true) throws -> (ClassificationPlanEngine, ClassificationPolicyStore, ClassificationClock) {
        let pointer = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(pointer) }
        let directory = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = ClassificationPolicyStore(directory: directory)
        let policy = ClassificationPolicy(version: 1, categories: [.init(id: "news", label: "電子報")], rules: [
            .init(id: "news", category: "news", conditions: [.init(field: .sender, match: .equals, value: "news@example.invalid")], action: .trash, enabled: true)])
        _ = try store.configure(policy, approving: approved ? ["news"] : [], confirmed: approved)
        let clock = ClassificationClock()
        return (ClassificationPlanEngine(store: store, clock: { clock.now() }), store, clock)
    }
    private func message(_ id: String = "12") -> ClassificationMessage {
        .init(id: id, accountID: "account", mailboxComponents: ["INBOX"], mailboxURL: "imap://account/INBOX",
              messageID: "<\(id)@example.invalid>", sender: "news@example.invalid", subject: "PRIVATE SUBJECT SENTINEL",
              listID: nil, isDraft: false, isFlagged: false, contentDigest: String(repeating: "a", count: 64))
    }

    func test_started_audit_precedes_move_and_item_is_not_retried() async throws {
        let (engine, store, _) = try setup()
        let msg = message()
        let plan = try await engine.makePlan(messages: [msg])
        let calls = ClassificationCalls()
        let result = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: false,
            refresh: { _ in msg }, move: { current, _, _ in
                let audit = try String(contentsOf: store.directory.appendingPathComponent("classification-audit.jsonl"), encoding: .utf8)
                XCTAssertTrue(audit.contains("started"))
                XCTAssertFalse(audit.contains(msg.subject))
                await calls.record(current.id)
                return .moved
            })
        XCTAssertEqual(result.items[0].status, .moved)
        do {
            _ = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: false,
                refresh: { _ in msg }, move: { _, _, _ in await calls.record("duplicate"); return .moved })
            XCTFail("must reject already attempted item")
        } catch {}
        let recorded = await calls.ids
        XCTAssertEqual(recorded, [msg.id])
    }

    func test_unapproved_rule_requires_preview_confirmation() async throws {
        let (engine, _, _) = try setup(approved: false)
        let msg = message()
        let plan = try await engine.makePlan(messages: [msg])
        do {
            _ = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: false,
                                       refresh: { _ in msg }, move: { _, _, _ in XCTFail("not approved"); return .moved })
            XCTFail("missing confirmation")
        } catch {}
        let result = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: true,
                                           refresh: { _ in msg }, move: { _, _, _ in .moved })
        XCTAssertEqual(result.items[0].status, .moved)
    }

    func test_expired_plan_and_revoked_approval_refuse_before_dispatch() async throws {
        let (engine, store, clock) = try setup()
        let msg = message()
        let plan = try await engine.makePlan(messages: [msg])
        clock.advance(301)
        do {
            _ = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: false,
                refresh: { _ in msg }, move: { _, _, _ in XCTFail("expired"); return .moved })
            XCTFail("expired")
        } catch {}
        let fresh = try await engine.makePlan(messages: [msg])
        _ = try store.configure(store.load().policy, revoking: ["news"])
        do {
            _ = try await engine.apply(planID: fresh.planID, ids: [msg.id], confirmed: false,
                refresh: { _ in msg }, move: { _, _, _ in XCTFail("revoked"); return .moved })
            XCTFail("revoked policy")
        } catch {}
    }

    func test_changed_content_is_not_dispatched() async throws {
        let (engine, _, _) = try setup()
        let msg = message()
        var changed = msg; changed.contentDigest = String(repeating: "b", count: 64)
        let updated = changed
        let plan = try await engine.makePlan(messages: [msg])
        let result = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: false,
            refresh: { _ in updated }, move: { _, _, _ in XCTFail("changed"); return .moved })
        XCTAssertEqual(result.items[0].status, .notAttempted)
        XCTAssertEqual(result.items[0].reason, "message_changed")
    }

    func test_unknown_outcome_stops_batch_and_cannot_retry_that_item() async throws {
        let (engine, _, _) = try setup()
        let first = message(), second = message("13")
        let plan = try await engine.makePlan(messages: [first, second])
        let result = try await engine.apply(planID: plan.planID, ids: [first.id, second.id], confirmed: false,
            refresh: { id in id == first.id ? first : second }, move: { _, _, _ in throw CocoaError(.fileReadUnknown) })
        XCTAssertEqual(result.items.map(\.status), [.outcomeUnknown, .notAttempted])
        let retry = try await engine.apply(planID: plan.planID, ids: [second.id], confirmed: false,
            refresh: { _ in second }, move: { _, _, _ in .moved })
        XCTAssertEqual(retry.items[0].status, .moved)
    }

    func test_audit_failure_prevents_move() async throws {
        let (engine, store, _) = try setup()
        let msg = message()
        let plan = try await engine.makePlan(messages: [msg])
        let file = store.directory.appendingPathComponent("classification-audit.jsonl")
        try Data("partial".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let result = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: false,
            refresh: { _ in msg }, move: { _, _, _ in XCTFail("audit failed"); return .moved })
        XCTAssertEqual(result.items[0].reason, "audit_unavailable")
        XCTAssertEqual(result.items[0].status, .notAttempted)
    }

    func test_policy_change_during_move_stops_remaining_items() async throws {
        let (engine, store, _) = try setup()
        let first = message(), second = message("13")
        let plan = try await engine.makePlan(messages: [first, second])
        let result = try await engine.apply(planID: plan.planID, ids: [first.id, second.id], confirmed: false,
            refresh: { id in id == first.id ? first : second }, move: { _, _, _ in
                _ = try await engine.configure(store.load().policy, revoking: ["news"])
                return .moved
            })
        XCTAssertEqual(result.items.map(\.status), [.moved, .notAttempted])
        XCTAssertEqual(result.items[1].reason, "policy_changed")
    }

    func test_whole_selection_is_validated_before_any_move() async throws {
        let (engine, _, _) = try setup()
        let msg = message()
        let plan = try await engine.makePlan(messages: [msg])
        do {
            _ = try await engine.apply(planID: plan.planID, ids: [msg.id, "99"], confirmed: false,
                refresh: { _ in msg }, move: { _, _, _ in XCTFail("invalid selection"); return .moved })
            XCTFail("unknown selection")
        } catch {}
        do { _ = try await engine.makePlan(messages: [msg, msg]); XCTFail("duplicate") } catch {}
        var alias = msg; alias.id = "012"
        do { _ = try await engine.makePlan(messages: [alias]); XCTFail("noncanonical id") } catch {}
    }
    func test_expiry_during_refresh_prevents_audit_and_move() async throws {
        let (engine, store, clock) = try setup()
        let msg = message()
        let plan = try await engine.makePlan(messages: [msg])
        let result = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: false,
            refresh: { _ in clock.advance(301); return msg }, move: { _, _, _ in XCTFail("expired during refresh"); return .moved })
        XCTAssertEqual(result.items[0].status, .notAttempted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("classification-audit.jsonl").path))
    }

    func test_outcome_audit_failure_does_not_replay_move() async throws {
        let (engine, store, _) = try setup()
        let msg = message()
        let plan = try await engine.makePlan(messages: [msg])
        let result = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: false,
            refresh: { _ in msg }, move: { _, _, _ in
                let path = store.directory.appendingPathComponent("classification-audit.jsonl")
                try Data("partial".utf8).write(to: path)
                return .moved
            })
        XCTAssertEqual(result.items[0].status, .moved)
        XCTAssertFalse(result.items[0].auditRecorded)
        do {
            _ = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: false,
                refresh: { _ in msg }, move: { _, _, _ in XCTFail("must not repeat"); return .moved })
            XCTFail("already attempted")
        } catch {}
    }

    func test_reentrant_apply_cannot_dispatch_twice() async throws {
        let (engine, _, _) = try setup()
        let msg = message()
        let plan = try await engine.makePlan(messages: [msg])
        let result = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: false,
            refresh: { _ in msg }, move: { _, _, _ in
                do {
                    _ = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: false,
                        refresh: { _ in msg }, move: { _, _, _ in XCTFail("duplicate in flight"); return .moved })
                    XCTFail("busy")
                } catch {}
                return .moved
            })
        XCTAssertEqual(result.items[0].status, .moved)
    }

    func test_unknown_identity_is_blocked_in_other_plan_and_new_engine() async throws {
        let (engine, store, clock) = try setup()
        let msg = message()
        let first = try await engine.makePlan(messages: [msg])
        let second = try await engine.makePlan(messages: [msg])
        _ = try await engine.apply(planID: first.planID, ids: [msg.id], confirmed: false,
            refresh: { _ in msg }, move: { _, _, _ in throw CocoaError(.fileReadUnknown) })
        let blocked = try await engine.apply(planID: second.planID, ids: [msg.id], confirmed: false,
            refresh: { _ in msg }, move: { _, _, _ in XCTFail("other plan must not retry"); return .moved })
        XCTAssertEqual(blocked.items[0].reason, "identity_already_attempted")
        let restarted = ClassificationPlanEngine(store: store, clock: { clock.now() })
        let newPlan = try await restarted.makePlan(messages: [msg])
        XCTAssertFalse(newPlan.items[0].automaticTrashAllowed)
        let result = try await restarted.apply(planID: newPlan.planID, ids: [msg.id], confirmed: true,
            refresh: { _ in msg }, move: { _, _, _ in XCTFail("confirmation cannot erase unknown history"); return .moved })
        XCTAssertEqual(result.items[0].reason, "identity_already_attempted")
    }

    func test_persisted_started_blocks_even_without_terminal_audit() async throws {
        let (engine, store, _) = try setup()
        let msg = message()
        let digest = try store.load().fingerprint()
        try store.reserveDispatch(msg, planID: UUID().uuidString, policyDigest: digest, now: Date())
        let plan = try await engine.makePlan(messages: [msg])
        XCTAssertFalse(plan.items[0].automaticTrashAllowed)
        let result = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: true,
            refresh: { _ in msg }, move: { _, _, _ in XCTFail("started must survive restart"); return .moved })
        XCTAssertEqual(result.items[0].status, .notAttempted)
    }

    /// A move that never reached osascript is a definitive no-op: the item is
    /// refused, its identity stays free and the batch goes on (#356 verify).
    func test_not_dispatched_is_refused_and_leaves_identity_free() async throws {
        let (engine, _, _) = try setup()
        let first = message("12"), second = message("13")
        let plan = try await engine.makePlan(messages: [first, second])
        let calls = ClassificationCalls()
        let result = try await engine.apply(planID: plan.planID, ids: [first.id, second.id], confirmed: false,
            refresh: { id in id == first.id ? first : second }, move: { current, _, _ in
                await calls.record(current.id)
                return current.id == first.id ? .notDispatched : .moved
            })
        XCTAssertEqual(result.items[0].status, .refused)
        XCTAssertEqual(result.items[0].reason, "not_dispatched")
        XCTAssertEqual(result.items[1].status, .moved)
        let again = try await engine.makePlan(messages: [first])
        let retry = try await engine.apply(planID: again.planID, ids: [first.id], confirmed: false,
            refresh: { _ in first }, move: { current, _, _ in await calls.record(current.id); return .moved })
        XCTAssertEqual(retry.items[0].status, .moved, "a fresh classification may try it again")
        let recorded = await calls.ids
        XCTAssertEqual(recorded, ["12", "13", "12"])
    }

    /// An identity already attempted affects only its own item (#356 verify).
    func test_identity_already_attempted_does_not_stop_the_batch() async throws {
        let (engine, store, _) = try setup()
        let blocked = message("12"), fresh = message("13")
        try store.reserveDispatch(blocked, planID: UUID().uuidString, policyDigest: try store.load().fingerprint(), now: Date())
        let plan = try await engine.makePlan(messages: [blocked, fresh])
        let result = try await engine.apply(planID: plan.planID, ids: [blocked.id, fresh.id], confirmed: true,
            refresh: { id in id == blocked.id ? blocked : fresh }, move: { _, _, _ in .moved })
        XCTAssertEqual(result.items[0].reason, "identity_already_attempted")
        XCTAssertEqual(result.items[1].status, .moved)
    }

    /// An item starts only with a whole native run left before the deadline,
    /// so a kill at the deadline cannot turn a refusal into an unknown outcome.
    func test_item_is_not_started_without_a_full_native_timeout_left() async throws {
        let (engine, store, clock) = try setup()
        let msg = message()
        let plan = try await engine.makePlan(messages: [msg])
        let result = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: false,
            refresh: { _ in clock.advance(60 - ClassificationPlanEngine.nativeItemTimeout + 1); return msg },
            move: { _, _, _ in XCTFail("not enough time left"); return .moved })
        XCTAssertEqual(result.items[0].status, .notAttempted)
        XCTAssertEqual(result.items[0].reason, "plan_or_batch_deadline")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("classification-audit.jsonl").path))
    }

    /// A failed outcome audit keeps the item's own reason.
    func test_outcome_audit_failure_keeps_the_unknown_reason() async throws {
        let (engine, store, _) = try setup()
        let msg = message()
        let plan = try await engine.makePlan(messages: [msg])
        let result = try await engine.apply(planID: plan.planID, ids: [msg.id], confirmed: false,
            refresh: { _ in msg }, move: { _, _, _ in
                try Data("partial".utf8).write(to: store.directory.appendingPathComponent("classification-audit.jsonl"))
                throw CocoaError(.fileReadUnknown)
            })
        XCTAssertEqual(result.items[0].status, .outcomeUnknown)
        XCTAssertEqual(result.items[0].reason, "native_outcome_unknown; outcome_audit_unavailable")
    }
}
