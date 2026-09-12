import Foundation

/// Transport data only. A decoded found record is NOT creation evidence and
/// must never authorize deletion without the trusted binding/recipient checks.
struct DraftReceiptWireRecord: Equatable {
    let accountID: UUID
    let id: String
    let subject: String
    let to: [String]
    let cc: [String]
    let bcc: [String]
}

enum DraftReceiptUnavailableReason: String, Equatable {
    case missingScope = "missing_scope"
    case identityUnproven = "identity_unproven"
    case readFailed = "read_failed"
    case invalidPayload = "invalid_payload"
    case wrongScope = "wrong_scope"
}

enum DraftReceiptWireOutcome: Equatable {
    case found(DraftReceiptWireRecord)
    case notFound
    case ambiguous(candidateCount: Int)
    case unavailable(DraftReceiptUnavailableReason)
}

/// #409/#427 protocol foundation. Not connected to the legacy receipt reader
/// until the creation adapter has passed its live evidence gate.
func decodeDraftReceiptWire(_ data: Data, expectedAccountID: UUID) -> DraftReceiptWireOutcome {
    let invalid = DraftReceiptWireOutcome.unavailable(.invalidPayload)
    guard let value = try? JSONSerialization.jsonObject(with: data),
          let object = value as? [String: Any],
          object["version"] as? String == "1",
          let status = object["status"] as? String else { return invalid }
    let keys = Set(object.keys)
    let common: Set<String> = ["version", "status"]
    switch status {
    case "found":
        guard keys == common.union(["account_id", "id", "subject", "to", "cc", "bcc"]),
              let accountText = object["account_id"] as? String,
              let account = UUID(uuidString: accountText),
              let id = object["id"] as? String, isASCIIDigits(id),
              let subject = object["subject"] as? String,
              let to = object["to"] as? [String],
              let cc = object["cc"] as? [String],
              let bcc = object["bcc"] as? [String] else { return invalid }
        guard account == expectedAccountID else { return .unavailable(.wrongScope) }
        return .found(DraftReceiptWireRecord(accountID: account, id: id, subject: subject,
                                             to: to, cc: cc, bcc: bcc))
    case "not_found":
        guard keys == common else { return invalid }
        return .notFound
    case "ambiguous":
        guard keys == common.union(["candidate_count"]),
              let text = object["candidate_count"] as? String, isASCIIDigits(text),
              let count = Int(text), count >= 2, String(count) == text else { return invalid }
        return .ambiguous(candidateCount: count)
    case "unavailable":
        guard keys == common.union(["reason_code"]),
              let code = object["reason_code"] as? String,
              let reason = DraftReceiptUnavailableReason(rawValue: code) else { return invalid }
        return .unavailable(reason)
    default:
        return invalid
    }
}
