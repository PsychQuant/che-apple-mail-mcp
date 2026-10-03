import Foundation

/// #465 — optional, best-effort masking of three identifier shapes in the
/// detailed output: angle-bracketed Message-IDs, email addresses, UUIDs.
///
/// **Not a privacy guarantee.** Account display names and mailbox names do not
/// have a recognizable shape and are left alone; the response says so. Numbers
/// are assigned in order of first appearance and stay stable for the whole
/// response, so a caller can still tell "the same address twice".
struct IdentifierRedactor {
    static let patternNames = ["email", "uuid", "message-id"]

    private static let messageID = try! NSRegularExpression(pattern: #"<[^<>\s@]+@[^<>\s]+>"#)
    /// The lookbehind makes a match start only at the beginning of a run of local-part characters;
    /// without it every position of a long run was a start and the scan was quadratic (measured: 5 s
    /// for one 8192-character message). Shared with `TemplateExtractor.looksLikeData`.
    static let emailPattern = #"(?<![A-Za-z0-9._%+\-])[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}"#
    private static let email = try! NSRegularExpression(pattern: emailPattern)
    private static let uuid = try! NSRegularExpression(
        pattern: #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#)

    /// The same three shapes replaced by un-numbered placeholders (`<email>` …). Used to match
    /// `contains` against masked text without disturbing the numbering of the returned messages.
    static func masked(_ text: String) -> String {
        var out = text
        for (regex, kind) in [(messageID, "message-id"), (email, "email"), (uuid, "uuid")] {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "<\(kind)>")
        }
        return out
    }

    /// kind → (lowercased matched text → number)
    private var numbers: [String: [String: Int]] = [:]

    /// Message-IDs go first: they contain an address, and masking the address
    /// alone would leave the surrounding `<…>` shape looking like an email slot.
    mutating func redact(_ text: String) -> String {
        var out = text
        out = apply(Self.messageID, kind: "message-id", to: out)
        out = apply(Self.email, kind: "email", to: out)
        out = apply(Self.uuid, kind: "uuid", to: out)
        return out
    }

    private mutating func apply(_ regex: NSRegularExpression, kind: String, to text: String) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var replacements: [(NSRange, String)] = []
        for m in matches {
            let key = ns.substring(with: m.range).lowercased()
            let n: Int
            if let existing = numbers[kind]?[key] {
                n = existing
            } else {
                n = (numbers[kind]?.count ?? 0) + 1
                numbers[kind, default: [:]][key] = n
            }
            replacements.append((m.range, "<\(kind)-\(n)>"))
        }
        let result = NSMutableString(string: text)
        for (range, replacement) in replacements.reversed() {
            result.replaceCharacters(in: range, with: replacement)
        }
        return result as String
    }
}
