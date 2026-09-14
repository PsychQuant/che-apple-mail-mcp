import Foundation
import MCP

struct ComposeSignatureSelection: Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case mailDefault = "mail_default", none, named }
    var mode: Mode
    var name: String? = nil
    static let mailDefault = ComposeSignatureSelection(mode: .mailDefault)

    func validated() throws -> Self {
        if mode == .named {
            guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.count <= 256,
                  !name.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }) else {
                throw MailError.invalidParameter("signature named mode requires a nonempty single-line name")
            }
        } else if name != nil {
            throw MailError.invalidParameter("signature.name is only valid with mode named")
        }
        return self
    }

    static func parse(_ value: Value?) throws -> Self {
        guard let value else { return .mailDefault }
        guard let object = value.objectValue, Set(object.keys).isSubset(of: ["mode", "name"]),
              let rawMode = object["mode"]?.stringValue, let mode = Mode(rawValue: rawMode) else {
            throw MailError.invalidParameter("signature requires mode mail_default, none or named")
        }
        if let value = object["name"], value.stringValue == nil {
            throw MailError.invalidParameter("signature.name must be a string")
        }
        return try Self(mode: mode, name: object["name"]?.stringValue).validated()
    }

    static let schema: Value = .object([
        "type": .string("object"), "additionalProperties": .bool(false),
        "properties": .object([
            "mode": .object(["type": .string("string"), "enum": .array([.string("mail_default"), .string("none"), .string("named")])]),
            "name": .object(["type": .string("string"), "description": .string("Exact unique Mail signature name; required only for named mode")])
        ]), "required": .array([.string("mode")]),
        "description": .string("Mail-managed signature selection. Omit or mail_default to preserve Mail's current choice, none to disable its native signature, named to clear and select an exact signature after From selection. Body must contain only the intended message text; the tool never appends or heuristically removes a manual signature. Reports selection, not proof of body insertion. Until actual body behavior is verified for this Mail setup, create and inspect a draft before a formal send; alternatively use none with caller-supplied signature text. Explicit selection refuses unsupported UI instead of guessing.")
    ])
}

struct ComposeSignatureReceipt: Codable, Equatable {
    var mode: ComposeSignatureSelection.Mode
    var selection: String
    var selectionVerified: Bool
    var selectionApplied: Bool
    enum CodingKeys: String, CodingKey {
        case mode, selection
        case selectionApplied = "selection_applied"
        case selectionVerified = "selection_verified"
    }
    static let marker = " [signature-receipt:"

    static func extract(from result: inout String, requested: ComposeSignatureSelection) throws -> Self? {
        guard let start = result.range(of: marker, options: .backwards), result.hasSuffix("]") else {
            if requested.mode == .mailDefault { return nil } // legacy test/older receipt producer
            throw MailError.operationFailed("signature selection receipt unavailable after dispatch")
        }
        let encoded = String(result[start.upperBound..<result.index(before: result.endIndex)])
        guard let data = Data(base64Encoded: encoded) else { throw MailError.operationFailed("invalid signature receipt encoding") }
        let receipt = try JSONDecoder().decode(Self.self, from: data)
        guard receipt.mode == requested.mode,
              !receipt.selectionVerified || !receipt.selection.isEmpty,
              requested.mode != .mailDefault || !receipt.selectionApplied,
              requested.mode == .mailDefault || (receipt.selectionVerified && receipt.selectionApplied),
              requested.mode != .named || receipt.selection == requested.name,
              requested.mode != .none || ["None", "無"].contains(receipt.selection) else {
            throw MailError.operationFailed("signature selection receipt did not match request")
        }
        result.removeSubrange(start.lowerBound...)
        return receipt
    }

    var disclosure: String {
        let encoded = (try? JSONEncoder().encode(selection)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return " [signature_mode: \(mode.rawValue); signature_selection: \(encoded); selection_verified: \(selectionVerified); body_insertion_verified: false]"
    }
}


let composeSignatureToolDescription = "Signature: the tool never appends a handwritten signature to body. Use signature.mode named (with exact Mail name) or none for an explicit native selection; omit/mail_default to leave Mail's selection unchanged. Pass message text only when Mail supplies the signature, or choose none when body already includes a manual signature. Selection is reported separately and is not proof of body insertion. This tool does not guarantee the signature appears in the body: verify a draft on first use of this Mail setup before formal sending, or use none plus caller-supplied signature text. Unsupported explicit UI selection refuses before dispatch."
