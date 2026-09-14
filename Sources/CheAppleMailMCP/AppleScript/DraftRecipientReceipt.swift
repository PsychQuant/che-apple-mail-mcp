import Foundation

// MARK: - #404 post-save recipient receipt

/// The cc / bcc addresses Mail stored on the saved draft, as read back through
/// the AppleScript object model. The AX token read-back in the fill phase can
/// only see display names (a token exposes no address over AX — live probe
/// 2026-09-07), so this receipt is the only evidence that the ADDRESSES landed.
struct RecipientReceipt: Equatable {
    let ccFound: [String]
    let bccFound: [String]
}

/// Script: locate the NEWEST draft (highest message id) whose subject equals
/// `subject` exactly, across every account's drafts mailbox, and return its cc
/// and bcc addresses as `cc1␞cc2␝bcc1` (ASCII 30 between addresses, ASCII 29
/// between the two lists); `NOTFOUND` when no draft carries the subject.
///
/// Newest-id wins is a heuristic, not a guarantee: `update_draft` keeps the old
/// draft (same subject) until its own receipt confirms the replacement, so the
/// newest same-subject draft is USUALLY the replacement — but message ids are
/// raw per-store ROWIDs that do not compare across accounts, and #405 shows an
/// old draft can be re-saved under a higher id, so the receipt MAY read the old
/// draft's recipients (PR #407 R3; a stronger identification is #409). The subject
/// comparison runs under `considering case` for parity with the Swift `==`
/// that `update_draft`'s receipt applies to `parseDraftRows`.
func buildDraftRecipientReceiptScript(subject: String) -> String {
    return """
    -- #404 recipient receipt
    tell application "Mail"
        set _best to missing value
        set _bestId to -1
        considering case
            repeat with mb in (every mailbox of drafts mailbox)
                repeat with dm in (every message of mb)
                    try
                        if ((subject of dm) as string) is "\(appleScriptEscape(subject))" then
                            if (id of dm) > _bestId then
                                set _bestId to (id of dm)
                                set _best to dm
                            end if
                        end if
                    end try
                end repeat
            end repeat
        end considering
        if _best is missing value then return "NOTFOUND"
        set ccStr to ""
        set firstCc to true
        repeat with r in (cc recipients of _best)
            if firstCc then
                set firstCc to false
                set ccStr to (address of r) as string
            else
                set ccStr to ccStr & (ASCII character 30) & ((address of r) as string)
            end if
        end repeat
        set bccStr to ""
        set firstBcc to true
        repeat with r in (bcc recipients of _best)
            if firstBcc then
                set firstBcc to false
                set bccStr to (address of r) as string
            else
                set bccStr to bccStr & (ASCII character 30) & ((address of r) as string)
            end if
        end repeat
        return ccStr & (ASCII character 29) & bccStr
    end tell
    """
}

/// Only NOTFOUND means absence. Malformed transport data is an unavailable
/// receipt, never a found address list or a reason to poll again (#427).
private enum RecipientReceiptParseError: LocalizedError {
    case malformed
    var errorDescription: String? { "Recipient receipt payload is malformed; cc/bcc could not be parsed" }
}

func parseRecipientReceipt(_ raw: String) throws -> RecipientReceipt? {
    if raw.trimmingCharacters(in: .whitespacesAndNewlines) == "NOTFOUND" { return nil }
    // Found payloads have no whitespace framing: preserve every address byte.
    let halves = raw.split(separator: "\u{1D}", omittingEmptySubsequences: false)
    guard halves.count == 2 else { throw RecipientReceiptParseError.malformed }
    func addresses(_ group: Substring) throws -> [String] {
        if group.isEmpty { return [] }
        let values = group.split(separator: "\u{1E}", omittingEmptySubsequences: false).map(String.init)
        guard values.allSatisfy(hasReceiptAddressShape) else { throw RecipientReceiptParseError.malformed }
        return values
    }
    return try RecipientReceipt(ccFound: addresses(halves[0]), bccFound: addresses(halves[1]))
}

/// Validate the producer's bare-address shape, preserving quoted local parts
/// and international addresses. This is not a DNS/deliverability validator.
private func hasReceiptAddressShape(_ address: String) -> Bool {
    let scalars = Array(address.unicodeScalars)
    guard !scalars.isEmpty,
          !scalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
    var at: Int
    if scalars[0] == "\"" {
        var cursor = 1
        var escaped = false
        while cursor < scalars.count {
            let scalar = scalars[cursor]
            if escaped { escaped = false }
            else if scalar == "\\" { escaped = true }
            else if scalar == "\"" { break }
            cursor += 1
        }
        guard !escaped, cursor < scalars.count - 2,
              scalars[cursor] == "\"", scalars[cursor + 1] == "@" else { return false }
        at = cursor + 1
    } else {
        guard let separator = scalars.firstIndex(of: "@"), separator > 0 else { return false }
        at = separator
        let local = scalars[..<at]
        let atomPunctuation = Set("!#$%&'*+-/=?^_`{|}~".unicodeScalars)
        guard local.first != ".", local.last != ".",
              !String(String.UnicodeScalarView(local)).contains(".."),
              local.allSatisfy({ scalar in
                  if scalar == "." || atomPunctuation.contains(scalar) { return true }
                  if scalar.value < 128 { return CharacterSet.alphanumerics.contains(scalar) }
                  return !CharacterSet.whitespacesAndNewlines.contains(scalar)
              }) else { return false }
    }
    guard at < scalars.count - 1 else { return false }
    let domain = Array(scalars[(at + 1)...])
    if domain.first == "[" {
        guard domain.count > 2, domain.last == "]" else { return false }
        return domain.dropFirst().dropLast().allSatisfy { scalar in
            (33...126).contains(scalar.value) && scalar != "[" && scalar != "]" && scalar != "\\"
        }
    }
    guard domain.first != ".", domain.last != ".",
          !String(String.UnicodeScalarView(domain)).contains("..") else { return false }
    return domain.allSatisfy { scalar in
        if scalar == "." || scalar == "-" || scalar == "_" { return true }
        if scalar.value < 128 { return CharacterSet.alphanumerics.contains(scalar) }
        return !CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

/// What the receipt script run produced. Three states, not two (PR #407 R1 #3):
/// a script that could not run or a payload that could not be parsed is
/// NOT evidence of absence and must never be reported as "not found" — the
/// same distinction `ListDraftsScriptBuilder` draws with its 9276 / 9277 codes.
enum RecipientReceiptFetch: Equatable {
    case found(RecipientReceipt)
    case notFound
    case unavailable(String)
}

/// The receipt's verdict on the saved draft.
enum RecipientReceiptOutcome: Equatable {
    /// cc and bcc address sets both match the request.
    case verified
    /// The draft was read and its addresses DIFFER — definitive evidence.
    case mismatch(diffJSON: String)
    /// No draft with the subject was found after polling.
    case notFound(diffJSON: String)
    /// The receipt could not be read or parsed; nothing is established either way.
    case unavailable(reason: String)

    /// Only a read draft whose addresses differ is definitive; `update_draft`
    /// gates its delete on this alone (DA, PR #407 R1: gating on `unavailable`
    /// would leave two drafts on every update for the accounts #406 describes).
    var isDefinitiveMismatch: Bool {
        if case .mismatch = self { return true }
        return false
    }
}

/// Compare the caller's intended addresses (display names stripped via
/// `parseRecipient`) with what the draft holds, case-insensitively and
/// order-insensitively, and classify the run.
func recipientReceiptOutcome(
    expectedCc: [String], expectedBcc: [String], receipt: RecipientReceiptFetch
) -> RecipientReceiptOutcome {
    let wantCc = expectedCc.map { parseRecipient($0).address.lowercased() }
    let wantBcc = expectedBcc.map { parseRecipient($0).address.lowercased() }
    switch receipt {
    case .unavailable(let reason):
        return .unavailable(reason: reason)
    case .notFound:
        return .notFound(diffJSON: diffJSON(cc: (wantCc, []), bcc: (wantBcc, [])))
    case .found(let r):
        let gotCc = r.ccFound.map { $0.lowercased() }
        let gotBcc = r.bccFound.map { $0.lowercased() }
        if Set(wantCc) == Set(gotCc) && Set(wantBcc) == Set(gotBcc) { return .verified }
        return .mismatch(diffJSON: diffJSON(cc: (wantCc, gotCc), bcc: (wantBcc, gotBcc)))
    }
}

/// The disclosure appended to a draft result. Never a failure: a mismatch, a
/// missing draft, or an unavailable receipt is reported with
/// `recipients_verified: false` and the draft is KEPT — the failure direction
/// is always toward keeping drafts (#276). `recipients_diff` is a JSON object
/// (spec: an object, not prose) so a programmatic caller can parse it.
func recipientReceiptDisclosure(_ outcome: RecipientReceiptOutcome) -> String {
    switch outcome {
    case .verified:
        return " [recipients_verified: true — cc/bcc addresses read back from the saved draft]"
    case .mismatch(let json):
        return " [recipients_verified: false — the saved draft's recipients differ from the request; "
            + "draft KEPT for you to check; recipients_diff: \(json)]"
    case .notFound(let json):
        return " [recipients_verified: false — a draft with this subject was not found in the drafts "
            + "mailbox after saving; any draft that did land is KEPT; recipients_diff: \(json)]"
    case .unavailable(let reason):
        return " [recipients_verified: false — recipients_receipt: unavailable (\(reason)); the "
            + "receipt could not be read or parsed, so nothing is established about the saved recipients "
            + "— this is NOT a not-found; draft KEPT; check cc/bcc in Mail]"
    }
}

/// `{"cc":{"expected":[…],"found":[…]},"bcc":{"expected":[…],"found":[…]}}` —
/// hand-built so the key order is stable (cc, bcc; expected, found).
private func diffJSON(cc: ([String], [String]), bcc: ([String], [String])) -> String {
    func arr(_ xs: [String]) -> String { "[" + xs.map { "\"" + jsonEscape($0) + "\"" }.joined(separator: ",") + "]" }
    func field(_ pair: ([String], [String])) -> String { "{\"expected\":\(arr(pair.0)),\"found\":\(arr(pair.1))}" }
    return "{\"cc\":\(field(cc)),\"bcc\":\(field(bcc))}"
}

private func jsonEscape(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) } else { out.unicodeScalars.append(ch) }
        }
    }
    return out
}

/// The tag `buildMailtoComposeScript` appends to its return value when the
/// fill phase revealed the Bcc field; translated into the result disclosure.
let bccFieldRevealedScriptTag = " [bcc-field-revealed]"
