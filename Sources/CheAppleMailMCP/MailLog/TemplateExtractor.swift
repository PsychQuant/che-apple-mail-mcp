import Foundation

/// How a brief event relates to its format template.
enum EventKind: String, Equatable {
    /// The template matched; `args` holds its integer slots.
    case structured
    /// Nothing reliable can be said beyond the template itself (placeholder-only
    /// template, or the message did not match it). `args` is empty.
    case unstructured
    /// A closed-list event recognized by `KnownEvents`.
    case known
}

struct TemplateExtraction: Equatable {
    let kind: EventKind
    let args: [Int?]
}

/// #465 — pulls the integer arguments out of a composed log message by walking
/// its `formatString` as a token sequence.
///
/// **Why not one big regex.** Log text derives partly from mail content (a
/// subject can land in a `%@`). A template with several `%@` turned into
/// `(.*?)…(.*?)` backtracks polynomially against a long non-matching message,
/// so a crafted subject could stall the server. Walking literal / integer /
/// wildcard tokens is linear. The price is that an ambiguous template is judged
/// `unstructured` — a safe degradation, never a wrong number: the message must
/// be consumed exactly to its end or nothing is reported.
///
/// **Where a wildcard's text ends.** A `%@` is filled by someone else (an
/// account or mailbox name, sometimes chosen by a server or a folder's owner),
/// so its text may contain the template's own literals and digits. The
/// template is cut at its wildcards into segments, and each segment is placed
/// by the one anchor that text cannot move:
///
/// * the **head** (before the first wildcard) from the start of the message;
/// * the **tail** (after the last wildcard) from the END of the message — it
///   must consume exactly to the end, and exactly one placement may do so;
/// * a **middle** segment (between two wildcards) has no anchor: if it carries
///   integers it must occur exactly once there, or nothing is reported
///   (verify round 1, finding #35 — a planted `count 99999 items`); without
///   integers it only has to exist.
///
/// An integer directly beside a wildcard has no boundary (`abc12`: is it 12 or
/// 2?) and makes the event `unstructured`. Verify round 2, finding 6: the round-1
/// rule demanded uniqueness after EVERY wildcard and so rejected templates that
/// reuse their own separator, such as `%{public}@ %lu messages expunged` behind a
/// bracket with a space in it (19 templates, ~11,000 of 382,806 real events).
enum TemplateExtractor {

    private enum Token {
        case literal(String)
        case integer
        case wildcard
    }

    /// Group 1: optional `{decorator}`; group 2: the conversion character.
    private static let specifier = try! NSRegularExpression(
        pattern: #"^%(\{[^}]*\})?[-+ #0]*[0-9*]*(?:\.[0-9*]+)?(?:hh|h|ll|l|z|t|j|q|L)?([A-Za-z@])"#)

    /// Decorators that only change *visibility*, so the value is still a plain
    /// number. Anything else (`{bool}`, `{darwin.errno}`, …) prints words.
    private static let plainDecorators: Set<String> = ["public", "private", "sensitive"]

    /// Real templates carry at most 16 placeholders (811 distinct templates measured); more than this is not
    /// parsed, which bounds the matcher's work (verify round 4, finding 14).
    static let maxPlaceholders = 64
    /// An integer argument is at most 20 digits (UInt64 has 20); a longer run is not one. This also bounds how
    /// far one placement can scan (verify round 6, findings 4/6/14: re-scanning a digit run from every candidate
    /// took 63 s on 65,536 digits).
    static let maxIntegerDigits = 20
    /// A middle segment that carries integers examines at most this many placements; past it, the placement
    /// is not proven unique and nothing is reported.
    static let maxMiddlePlacements = 1024

    static func extract(formatString: String, message: String) -> TemplateExtraction {
        let tokens = tokenize(formatString)
        let placeholders = tokens.reduce(0) { n, t in if case .literal = t { return n } else { return n + 1 } }
        guard placeholders <= maxPlaceholders else { return TemplateExtraction(kind: .unstructured, args: []) }
        let hasInteger = tokens.contains { if case .integer = $0 { return true } else { return false } }
        guard hasLiteralText(tokens) || hasInteger, let args = match(tokens, message) else {
            return TemplateExtraction(kind: .unstructured, args: [])
        }
        return TemplateExtraction(kind: .structured, args: args)
    }

    private static let placeholder = try! NSRegularExpression(
        pattern: #"%(\{[^}]*\})?[-+ #0]*[0-9*]*(\.[0-9*]+)?(hh|h|ll|l|z|t|j|q|L)?[A-Za-z@]"#)
    /// The redaction pattern itself, lookbehind included (without it the scan is quadratic on a
    /// long run of local-part characters — verify round 2, finding 3).
    static let emailShapePattern = IdentifierRedactor.emailPattern
    private static let emailShape = try! NSRegularExpression(pattern: emailShapePattern)
    /// The longest template measured in eight hours of real log is 351 characters. Counted in UTF-8
    /// BYTES: one Character can be dozens of bytes (verify round 3, finding 1).
    static let maxTemplateBytes = 1024
    private static let uuidShape = try! NSRegularExpression(
        pattern: #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#)

    /// Backstop for "the brief output cannot carry data": it rests on `formatString` being a
    /// compile-time string. A code path that logged a runtime string AS the format would put data
    /// there, so a template that itself looks like an email address or a UUID is withheld.
    /// Printf placeholders are blanked first — `<%{public}@@%{public}@>` is a template for where a
    /// Message-ID is printed, not one.
    static func looksLikeData(_ formatString: String) -> Bool {
        // Longer than any real template: withheld unscanned, which also bounds every regex below.
        guard formatString.utf8.count <= maxTemplateBytes else { return true }
        var text = placeholder.stringByReplacingMatches(in: formatString, range: NSRange(formatString.startIndex..., in: formatString), withTemplate: "PH")
        while text.contains("PH@PH") { text = text.replacingOccurrences(of: "PH@PH", with: "PH") }
        let range = NSRange(text.startIndex..., in: text)
        return emailShape.firstMatch(in: text, range: range) != nil || uuidShape.firstMatch(in: text, range: range) != nil
    }

    /// `true` when the TEMPLATE places a `[account - mailbox]` bracket at the start of the message,
    /// so a leading bracket there is Mail's account prefix rather than runtime text that merely starts
    /// with one (verify round 2, finding 18). Two shapes, and only these two:
    ///
    /// 1. the template opens with a wildcard and has literal text of its own
    ///    (`%@ Received %lu new local message actions`) — the wildcard is the bracket;
    /// 2. the template itself opens with `[`, a wildcard, then ` - `
    ///    (`[%{public}@ - %{public}@] Reset mailbox in sync state`) — the first slot is the account.
    ///
    /// A placeholder-only template (`%{public}@`) is neither: its whole message is runtime text.
    static func carriesAccountPrefix(_ formatString: String) -> Bool {
        let tokens = tokenize(formatString)
        if case .wildcard? = tokens.first { return hasLiteralText(tokens) }
        guard tokens.count >= 3, case .literal("[") = tokens[0], case .wildcard = tokens[1],
              case .literal(let separator) = tokens[2] else { return false }
        return separator.hasPrefix(" - ")
    }

    /// `true` when the template contains any non-whitespace literal text.
    static func hasLiteralText(_ formatString: String) -> Bool {
        hasLiteralText(tokenize(formatString))
    }

    private static func hasLiteralText(_ tokens: [Token]) -> Bool {
        tokens.contains {
            if case .literal(let s) = $0 { return s.contains { !$0.isWhitespace } }
            return false
        }
    }

    // MARK: - Tokenizing

    private static func tokenize(_ format: String) -> [Token] {
        var tokens: [Token] = []
        var literal = ""
        func flush() { if !literal.isEmpty { tokens.append(.literal(literal)); literal = "" } }

        var index = format.startIndex
        while index < format.endIndex {
            let ch = format[index]
            guard ch == "%" else { literal.append(ch); index = format.index(after: index); continue }

            let next = format.index(after: index)
            if next < format.endIndex, format[next] == "%" {          // "%%" → one literal percent
                literal.append("%")
                index = format.index(after: next)
                continue
            }
            let rest = String(format[index...])
            let whole = NSRange(rest.startIndex..., in: rest)
            if let m = specifier.firstMatch(in: rest, range: whole),
               let matchRange = Range(m.range, in: rest),
               let conversionRange = Range(m.range(at: 2), in: rest) {
                flush()
                let decorators = Range(m.range(at: 1), in: rest).map { String(rest[$0]) }
                tokens.append(classify(decorators: decorators, conversion: rest[conversionRange]))
                index = format.index(index, offsetBy: rest.distance(from: rest.startIndex, to: matchRange.upperBound))
            } else {
                literal.append("%")                                   // a lone "%" that starts no specifier
                index = next
            }
        }
        flush()
        return tokens
    }

    /// `decorators` is the raw `{...}` text if present. Visibility-only decorators
    /// leave the value a plain number; anything else (`{bool}`, `{darwin.errno}`…)
    /// prints words, so it must not be read as an integer.
    private static func classify(decorators: String?, conversion: Substring) -> Token {
        if let decorators {
            let names = decorators.dropFirst().dropLast()
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if !names.allSatisfy({ plainDecorators.contains($0) }) { return .wildcard }
        }
        return conversion == "d" || conversion == "i" || conversion == "u" ? .integer : .wildcard
    }

    // MARK: - Matching

    private static func match(_ tokens: [Token], _ message: String) -> [Int?]? {
        var segments: [[Token]] = [[]]
        for token in tokens {
            if case .wildcard = token { segments.append([]) } else { segments[segments.count - 1].append(token) }
        }
        let whole = message.startIndex..<message.endIndex
        guard segments.count > 1 else {                                      // no wildcard at all
            guard let m = place(segments[0], in: message, at: message.startIndex, within: whole),
                  m.end == message.endIndex else { return nil }
            return m.args
        }
        for (i, segment) in segments.enumerated() {
            if i > 0, case .integer? = segment.first { return nil }          // wildcard, then integer
            if i < segments.count - 1, case .integer? = segment.last { return nil }   // integer, then wildcard
        }

        guard let head = place(segments[0], in: message, at: message.startIndex, within: whole) else { return nil }
        var tailStart = message.endIndex
        var tailArgs: [Int?] = []
        if let tail = segments.last, !tail.isEmpty {
            // A valid tail starts no further from the end than its longest possible text (its literals plus at most
            // 21 characters per integer slot), so the search — and its uniqueness check — need look no further back.
            let longest = tail.reduce(0) { n, t in
                if case .literal(let text) = t { return n + text.count }
                return n + maxIntegerDigits + 1
            }
            let from = message.index(message.endIndex, offsetBy: -longest, limitedBy: head.end) ?? head.end
            guard let fits = placements(of: tail, in: message, within: from..<message.endIndex, upTo: 2,
                                        examining: .max, accept: { $0 == message.endIndex }),
                  fits.count == 1 else { return nil }
            (tailStart, tailArgs) = (fits[0].start, fits[0].args)
        }
        var position = head.end
        var middleArgs: [Int?] = []
        for segment in segments.dropFirst().dropLast() where !segment.isEmpty {
            let carriesIntegers = segment.contains { if case .integer = $0 { return true } else { return false } }
            guard let found = placements(of: segment, in: message, within: position..<tailStart, upTo: carriesIntegers ? 2 : 1,
                                         examining: carriesIntegers ? maxMiddlePlacements : .max, accept: { _ in true }),
                  let first = found.first, !(carriesIntegers && found.count > 1) else { return nil }
            middleArgs += first.args
            position = first.end
        }
        return head.args + middleArgs + tailArgs
    }

    /// Matches a wildcard-free segment anchored at `start`, never past `bounds.upperBound`.
    private static func place(_ segment: [Token], in message: String, at start: String.Index,
                              within bounds: Range<String.Index>) -> (end: String.Index, args: [Int?])? {
        var position = start
        var args: [Int?] = []
        for token in segment {
            switch token {
            case .literal(let text):
                guard let r = message.range(of: text, options: .anchored, range: position..<bounds.upperBound) else { return nil }
                position = r.upperBound
            case .integer:
                if let r = message.range(of: "<private>", options: .anchored, range: position..<bounds.upperBound) {
                    args.append(nil)
                    position = r.upperBound
                } else {
                    var end = position
                    if end < bounds.upperBound, message[end] == "-" { end = message.index(after: end) }
                    let digitsStart = end
                    var digits = 0
                    while end < bounds.upperBound, message[end].isASCII, message[end].isNumber {
                        digits += 1
                        guard digits <= maxIntegerDigits else { return nil }
                        end = message.index(after: end)
                    }
                    guard end > digitsStart else { return nil }
                    args.append(Int(message[position..<end]))              // overflow → nil, never a crash
                    position = end
                }
            case .wildcard:
                return nil                                                  // segments hold no wildcards
            }
        }
        return (position, args)
    }

    /// Every placement of `segment` (which starts with a literal) inside `bounds` whose end satisfies
    /// `accept`, at most `limit` of them: callers only need "none", "one" or "more than one". `nil` when more
    /// than `examining` candidate positions had to be tried — the answer is then unknown, not "none".
    private static func placements(of segment: [Token], in message: String, within bounds: Range<String.Index>,
                                   upTo limit: Int, examining budget: Int, accept: (String.Index) -> Bool)
        -> [(start: String.Index, end: String.Index, args: [Int?])]? {
        guard case .literal(let first)? = segment.first else { return [] }
        var found: [(start: String.Index, end: String.Index, args: [Int?])] = []
        var from = bounds.lowerBound
        var examined = 0
        while found.count < limit, from < bounds.upperBound,
              let hit = message.range(of: first, range: from..<bounds.upperBound) {
            examined += 1
            if examined > budget { return nil }
            if let m = place(segment, in: message, at: hit.lowerBound, within: bounds), accept(m.end) {
                found.append((hit.lowerBound, m.end, m.args))
            }
            from = message.index(after: hit.lowerBound)
        }
        return found
    }
}
