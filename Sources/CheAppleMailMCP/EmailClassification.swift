import CryptoKit
import Foundation
import MailSQLite

enum ClassificationError: Error, LocalizedError {
    case invalidPolicy(String)
    case storage(String)
    case invalidPlan(String)

    var errorDescription: String? {
        switch self {
        case .invalidPolicy(let detail): return "Invalid classification policy: \(detail)"
        case .storage(let detail): return "Classification storage: \(detail)"
        case .invalidPlan(let detail): return "Invalid classification plan: \(detail)"
        }
    }
}

func classificationCanonicalData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

func classificationDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

enum ClassificationAction: String, Codable, Sendable { case keep, review, trash }
enum ClassificationField: String, Codable, Sendable { case sender, subject; case listID = "list_id" }
enum ClassificationMatch: String, Codable, Sendable { case equals, contains }

struct ClassificationCategory: Codable, Equatable, Sendable {
    var id: String
    var label: String
}

struct ClassificationCondition: Codable, Equatable, Sendable {
    var field: ClassificationField
    var match: ClassificationMatch
    var value: String
}

struct ClassificationRule: Codable, Equatable, Sendable {
    var id: String
    var category: String
    var conditions: [ClassificationCondition]
    var action: ClassificationAction
    var enabled: Bool

    func fingerprint() throws -> String {
        classificationDigest(try classificationCanonicalData(self))
    }
}

struct ClassificationPolicy: Codable, Equatable, Sendable {
    var version: Int
    var categories: [ClassificationCategory]
    var rules: [ClassificationRule]
    static let empty = ClassificationPolicy(version: 1, categories: [], rules: [])

    func canonicalData() throws -> Data { try classificationCanonicalData(self) }
    func fingerprint() throws -> String { classificationDigest(try canonicalData()) }

    static func decode(_ data: Data) throws -> ClassificationPolicy {
        // Codable alone ignores unknown keys; that would silently accept a
        // misspelled condition or a body field that the user thought was active.
        let raw = try JSONSerialization.jsonObject(with: data)
        func object(_ value: Any, fields: Set<String>) throws -> [String: Any] {
            guard let value = value as? [String: Any], Set(value.keys) == fields else {
                throw ClassificationError.invalidPolicy("unknown or missing fields")
            }
            return value
        }
        let root = try object(raw, fields: ["version", "categories", "rules"])
        guard let categories = root["categories"] as? [Any], let rules = root["rules"] as? [Any] else {
            throw ClassificationError.invalidPolicy("categories and rules must be arrays")
        }
        for category in categories { _ = try object(category, fields: ["id", "label"]) }
        for rule in rules {
            let value = try object(rule, fields: ["id", "category", "conditions", "action", "enabled"])
            guard let conditions = value["conditions"] as? [Any] else {
                throw ClassificationError.invalidPolicy("conditions must be an array")
            }
            for condition in conditions { _ = try object(condition, fields: ["field", "match", "value"]) }
        }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }

    func validated() throws -> ClassificationPolicy {
        func validID(_ value: String) -> Bool {
            value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
                && !value.contains(where: { $0.isWhitespace })
        }
        func safeValue(_ value: String, limit: Int) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit
                && !value.unicodeScalars.contains { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }
        }
        guard version == 1, categories.count <= 50, rules.count <= 200 else {
            throw ClassificationError.invalidPolicy("requires version 1, at most 50 categories and 200 rules")
        }
        var categoryIDs: Set<String> = []
        for category in categories {
            guard validID(category.id), !["unclassified", "conflict"].contains(category.id),
                  categoryIDs.insert(category.id).inserted, safeValue(category.label, limit: 100) else {
                throw ClassificationError.invalidPolicy("invalid, reserved or duplicate category")
            }
        }
        var normalized = self
        var ruleIDs: Set<String> = []
        for index in normalized.rules.indices {
            let rule = normalized.rules[index]
            guard validID(rule.id), ruleIDs.insert(rule.id).inserted, categoryIDs.contains(rule.category),
                  (1...8).contains(rule.conditions.count) else {
                throw ClassificationError.invalidPolicy("invalid rule id/category/condition count")
            }
            for conditionIndex in rule.conditions.indices {
                let condition = rule.conditions[conditionIndex]
                guard safeValue(condition.value, limit: 500),
                      condition.field == .subject || condition.match == .equals else {
                    throw ClassificationError.invalidPolicy("nonempty criteria required; contains is subject-only")
                }
                switch condition.field {
                case .sender:
                    let trimmed = condition.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let address = EmailAddress.singleCanonical(trimmed), address == trimmed.lowercased() else {
                        throw ClassificationError.invalidPolicy("sender criterion must be a bare email address")
                    }
                    normalized.rules[index].conditions[conditionIndex].value = address
                case .listID:
                    guard let list = EmailClassifier.canonicalListID(condition.value),
                          list == condition.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                        throw ClassificationError.invalidPolicy("list_id criterion must be an identifier without display text")
                    }
                    normalized.rules[index].conditions[conditionIndex].value = list
                case .subject:
                    break // significant leading/trailing spaces remain part of the criterion
                }
            }
        }
        return normalized
    }
}

struct ClassificationApproval: Codable, Equatable, Sendable {
    var ruleID: String
    var fingerprint: String
    var approvedAt: String
    enum CodingKeys: String, CodingKey {
        case ruleID = "rule_id", fingerprint, approvedAt = "approved_at"
    }
}

struct ClassificationMessage: Codable, Equatable, Sendable {
    var id: String
    var accountID: String
    var mailboxComponents: [String]
    var mailboxURL: String
    var messageID: String
    var sender: String
    var subject: String
    var listID: String?
    var isDraft: Bool?
    var isFlagged: Bool
    var contentDigest: String

    var hasVerifiableIdentity: Bool {
        func noControls(_ value: String) -> Bool {
            !value.unicodeScalars.contains { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }
        }
        guard contentDigest.utf8.count == 64,
              contentDigest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              id.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
              let numericID = Int(id), numericID > 0,
              !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, noControls(accountID),
              !mailboxComponents.isEmpty, mailboxComponents.allSatisfy({ !$0.isEmpty && noControls($0) }),
              messageID.hasPrefix("<"), messageID.hasSuffix(">"), messageID.count > 2,
              noControls(messageID), !messageID.contains(where: { $0.isWhitespace }) else { return false }
        // Conservative ASCII dot-atom subset. Quoted/obsolete forms remain
        // preview-only; do not call a merely bracketed string a verified id.
        let atom = #"[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+"#
        let dotAtom = atom + "(?:\\." + atom + ")*"
        return messageID.range(of: "^<" + dotAtom + "@" + dotAtom + ">$",
                               options: .regularExpression) != nil
    }

    func fingerprint() throws -> String {
        classificationDigest(try classificationCanonicalData(self))
    }

    enum CodingKeys: String, CodingKey {
        case id, subject, sender
        case accountID = "account_id", mailboxComponents = "mailbox_components", mailboxURL = "mailbox_url"
        case messageID = "message_id", listID = "list_id", isDraft = "is_draft", isFlagged = "is_flagged"
        case contentDigest = "content_digest"
    }
}

struct ClassificationDecision: Codable, Equatable, Sendable {
    var id: String
    var category: String
    var categoryLabel: String
    var action: ClassificationAction
    var matchedRules: [String]
    var authorizingRules: [String]
    var automaticTrashAllowed: Bool
    var reasons: [String]
    var subject: String
    var sender: String

    init(message: ClassificationMessage, category: String, categoryLabel: String,
         action: ClassificationAction, matchedRules: [String], authorizingRules: [String],
         automaticTrashAllowed: Bool, reasons: [String]) {
        self.id = message.id
        self.subject = message.subject
        self.sender = message.sender
        self.category = category
        self.categoryLabel = categoryLabel
        self.action = action
        self.matchedRules = matchedRules
        self.authorizingRules = authorizingRules
        self.automaticTrashAllowed = automaticTrashAllowed
        self.reasons = reasons
    }

    enum CodingKeys: String, CodingKey {
        case id, subject, sender, category, action, reasons
        case categoryLabel = "category_label", matchedRules = "matched_rules", authorizingRules = "authorizing_rules"
        case automaticTrashAllowed = "automatic_trash_allowed"
    }
}

enum EmailClassifier {
    static func canonicalListID(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = value.firstIndex(of: "<"), let close = value.lastIndex(of: ">") {
            guard open < close, value.filter({ $0 == "<" }).count == 1,
                  value.filter({ $0 == ">" }).count == 1,
                  value[value.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            value = String(value[value.index(after: open)..<close])
        }
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil,
              !value.contains(where: { $0.isWhitespace }) else { return nil }
        return value.lowercased()
    }

    static func classify(_ message: ClassificationMessage, policy rawPolicy: ClassificationPolicy,
                         approvals: [ClassificationApproval]) throws -> ClassificationDecision {
        let policy = try rawPolicy.validated()
        let matches = policy.rules.filter { rule in
            rule.enabled && rule.conditions.allSatisfy { condition in
                let actual: String?
                switch condition.field {
                case .sender: actual = EmailAddress.singleCanonical(message.sender)
                case .subject: actual = message.subject
                case .listID: actual = message.listID.flatMap(canonicalListID)
                }
                guard let actual else { return false }
                switch condition.match {
                case .equals: return actual.compare(condition.value, options: .caseInsensitive) == .orderedSame
                case .contains: return actual.range(of: condition.value, options: .caseInsensitive) != nil
                }
            }
        }
        guard let first = matches.first else {
            return .init(message: message, category: "unclassified", categoryLabel: "未分類", action: .review,
                         matchedRules: [], authorizingRules: [], automaticTrashAllowed: false,
                         reasons: [policy.rules.isEmpty ? "no_policy_rules" : "no_matching_rule"])
        }
        guard matches.allSatisfy({ $0.category == first.category && $0.action == first.action }) else {
            return .init(message: message, category: "conflict", categoryLabel: "規則衝突", action: .review,
                         matchedRules: matches.map(\.id), authorizingRules: [], automaticTrashAllowed: false,
                         reasons: ["conflicting_rules"])
        }
        var authorized: [String] = []
        for rule in matches where rule.action == .trash {
            let fingerprint = try rule.fingerprint()
            if approvals.contains(where: { $0.ruleID == rule.id && $0.fingerprint == fingerprint }) {
                authorized.append(rule.id)
            }
        }
        var reasons = ["rule_matched"]
        if first.action == .trash && authorized.isEmpty { reasons.append("rule_not_approved") }
        if !message.hasVerifiableIdentity { reasons.append("identity_unavailable") }
        if message.isDraft != false { reasons.append(message.isDraft == true ? "draft_protected" : "draft_status_unknown") }
        if message.isFlagged { reasons.append("flagged_protected") }
        let automatic = first.action == .trash && !authorized.isEmpty && message.hasVerifiableIdentity
            && message.isDraft == false && !message.isFlagged
        return .init(message: message, category: first.category,
                     categoryLabel: policy.categories.first(where: { $0.id == first.category })!.label,
                     action: first.action, matchedRules: matches.map(\.id), authorizingRules: authorized,
                     automaticTrashAllowed: automatic, reasons: reasons)
    }
}
