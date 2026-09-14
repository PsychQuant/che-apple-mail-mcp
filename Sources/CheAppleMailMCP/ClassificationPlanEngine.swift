import Foundation

func validateClassificationIDs(_ ids: [String]) throws {
    guard (1...200).contains(ids.count), Set(ids).count == ids.count,
          ids.allSatisfy({ id in Int(id).map { $0 > 0 && String($0) == id } ?? false }) else {
        throw ClassificationError.invalidPlan("requires 1...200 unique canonical positive id strings")
    }
}

struct ClassificationPlan: Codable, Sendable {
    let planID: String
    let expiresAt: String
    let policyDigest: String
    let items: [ClassificationDecision]
    enum CodingKeys: String, CodingKey {
        case planID = "plan_id", expiresAt = "expires_at", policyDigest = "policy_digest", items
    }
}

enum ClassificationMoveReceipt: String, Sendable {
    case moved, refused
    case alreadyInTrash = "already_in_trash"
}

struct ClassificationApplicationItem: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case moved, refused
        case alreadyInTrash = "already_in_trash", outcomeUnknown = "outcome_unknown", notAttempted = "not_attempted"
    }
    let id: String
    let status: Status
    let reason: String?
    let auditRecorded: Bool
    enum CodingKeys: String, CodingKey { case id, status, reason; case auditRecorded = "audit_recorded" }
}

struct ClassificationApplication: Codable, Sendable {
    let planID: String
    let items: [ClassificationApplicationItem]
    enum CodingKeys: String, CodingKey { case planID = "plan_id", items }
}

actor ClassificationPlanEngine {
    private struct Record {
        let expires: Date
        let envelopeDigest: String
        let messages: [String: ClassificationMessage]
        let decisions: [String: ClassificationDecision]
        var attempted: Set<String> = []
    }
    private let store: ClassificationPolicyStore
    private let clock: @Sendable () -> Date
    private var plans: [String: Record] = [:]
    private var applying = false

    init(store: ClassificationPolicyStore = .init(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.clock = clock
    }

    func policy() throws -> ClassificationPolicyEnvelope { try store.load() }

    func configure(_ policy: ClassificationPolicy, approving: [String] = [], revoking: [String] = [],
                   confirmed: Bool = false) throws -> ClassificationPolicyEnvelope {
        // A revocation can arrive while a native operation is in flight. The
        // in-flight attempt cannot be undone; every following item rechecks it.
        try store.configure(policy, approving: approving, revoking: revoking, confirmed: confirmed, now: clock())
    }

    func makePlan(messages: [ClassificationMessage]) throws -> ClassificationPlan {
        try validateClassificationIDs(messages.map(\.id))
        let now = clock()
        plans = plans.filter { $0.value.expires > now }
        guard plans.count < 32 else { throw ClassificationError.invalidPlan("too many live plans; wait for expiry") }
        let envelope = try store.load()
        let digest = try envelope.fingerprint()
        let decisions = try messages.map { message in
            var decision = try EmailClassifier.classify(message, policy: envelope.policy, approvals: envelope.approvals)
            if try store.dispatchBlocked(message) {
                decision.automaticTrashAllowed = false
                decision.reasons.append("previous_attempt_requires_verification")
            }
            return decision
        }
        let id = UUID().uuidString
        let expires = now.addingTimeInterval(300)
        plans[id] = Record(expires: expires, envelopeDigest: digest,
                           messages: Dictionary(uniqueKeysWithValues: messages.map { message in
                               var fingerprintOnly = message
                               fingerprintOnly.nativeSource = nil
                               return (message.id, fingerprintOnly)
                           }),
                           decisions: Dictionary(uniqueKeysWithValues: decisions.map { ($0.id, $0) }))
        return .init(planID: id, expiresAt: ISO8601DateFormatter().string(from: expires), policyDigest: digest, items: decisions)
    }

    func apply(planID: String, ids: [String], confirmed: Bool,
               refresh: @Sendable (String) async throws -> ClassificationMessage,
               move: @Sendable (ClassificationMessage, String, Date) async throws -> ClassificationMoveReceipt
    ) async throws -> ClassificationApplication {
        try validateClassificationIDs(ids)
        guard !applying else { throw ClassificationError.invalidPlan("another application is in progress") }
        guard let plan = plans[planID], clock() < plan.expires else {
            throw ClassificationError.invalidPlan("unknown or expired plan")
        }
        guard try store.load().fingerprint() == plan.envelopeDigest else {
            throw ClassificationError.invalidPlan("policy changed; classify again")
        }
        // Validate the ENTIRE explicit selection before any audit or movement.
        for id in ids {
            guard let decision = plan.decisions[id], let message = plan.messages[id],
                  !plan.attempted.contains(id), message.hasVerifiableIdentity,
                  decision.action == .trash, decision.automaticTrashAllowed || confirmed else {
                throw ClassificationError.invalidPlan("unknown, attempted, unverifiable or unconfirmed trash selection")
            }
        }
        applying = true
        defer { applying = false }
        let deadline = min(plan.expires, clock().addingTimeInterval(60))
        var results: [ClassificationApplicationItem] = []
        var stopReason: String?
        for id in ids {
            if let stopReason {
                results.append(.init(id: id, status: .notAttempted, reason: stopReason, auditRecorded: false))
                continue
            }
            if Task.isCancelled || clock() >= deadline {
                stopReason = Task.isCancelled ? "cancelled" : "plan_or_batch_deadline"
                results.append(.init(id: id, status: .notAttempted, reason: stopReason, auditRecorded: false))
                continue
            }
            let current: ClassificationMessage
            do { current = try await refresh(id) }
            catch {
                results.append(.init(id: id, status: .notAttempted, reason: "message_unavailable", auditRecorded: false))
                continue
            }
            guard current.id == id, try current.fingerprint() == plan.messages[id]!.fingerprint() else {
                results.append(.init(id: id, status: .notAttempted, reason: "message_changed", auditRecorded: false))
                continue
            }
            if Task.isCancelled || clock() >= deadline {
                stopReason = Task.isCancelled ? "cancelled" : "plan_or_batch_deadline"
                results.append(.init(id: id, status: .notAttempted, reason: stopReason, auditRecorded: false))
                continue
            }
            let currentPolicy: ClassificationPolicyEnvelope
            do {
                currentPolicy = try store.load()
                guard try currentPolicy.fingerprint() == plan.envelopeDigest else {
                    stopReason = "policy_changed"
                    results.append(.init(id: id, status: .notAttempted, reason: stopReason, auditRecorded: false))
                    continue
                }
            } catch {
                stopReason = "policy_unavailable"
                results.append(.init(id: id, status: .notAttempted, reason: stopReason, auditRecorded: false))
                continue
            }
            let decision = plan.decisions[id]!
            func event(_ outcome: ClassificationAuditEvent.Outcome) -> ClassificationAuditEvent {
                .init(timestamp: ISO8601DateFormatter().string(from: clock()), planID: planID, itemID: id,
                      messageIDDigest: classificationDigest(Data(current.messageID.utf8)),
                      ruleIDs: decision.matchedRules, category: decision.category, outcome: outcome,
                      policyDigest: plan.envelopeDigest,
                      accountID: current.accountID, sourceMailbox: current.mailboxComponents)
            }
            var reserved = false
            do {
                try store.archivePolicy(currentPolicy)
                try store.reserveDispatch(current, planID: planID, policyDigest: plan.envelopeDigest, now: clock())
                reserved = true
                try store.appendAudit(event(.started))
            }
            catch {
                if reserved { try? store.finishDispatch(current, planID: planID, outcome: .refused, now: clock()) }
                if case ClassificationError.invalidPlan(let reason) = error, reason == "identity_already_attempted" {
                    stopReason = "identity_already_attempted"
                } else {
                    stopReason = "audit_unavailable"
                }
                results.append(.init(id: id, status: .notAttempted, reason: stopReason, auditRecorded: false))
                continue
            }
            // Persisted audit precedes the capability handoff. From this point
            // the item is consumed even if native execution returns uncertainty.
            plans[planID]?.attempted.insert(id)
            let status: ClassificationApplicationItem.Status
            let auditOutcome: ClassificationAuditEvent.Outcome
            var reason: String?
            do {
                switch try await move(current, plan.envelopeDigest, deadline) {
                case .moved: status = .moved; auditOutcome = .moved
                case .alreadyInTrash: status = .alreadyInTrash; auditOutcome = .alreadyInTrash; reason = "already_in_trash"
                case .refused: status = .refused; auditOutcome = .refused; reason = "native_guard_refused"
                }
            } catch {
                status = .outcomeUnknown
                auditOutcome = .outcomeUnknown
                reason = "native_outcome_unknown"
                stopReason = "prior_outcome_unknown"
            }
            var recorded = true
            do {
                try store.finishDispatch(current, planID: planID,
                    outcome: auditOutcome, now: clock())
                try store.appendAudit(event(auditOutcome))
            }
            catch {
                recorded = false
                reason = "outcome_audit_unavailable"
                stopReason = "audit_unavailable"
            }
            results.append(.init(id: id, status: status, reason: reason, auditRecorded: recorded))
        }
        return .init(planID: planID, items: results)
    }
}
