import Foundation

/// Canonical bare-address extraction for RFC 5322 address fields (#343).
///
/// This exists because `direction` in the markdown export is decided by
/// comparing a sender against the set of the user's own addresses, and #316
/// built that comparison on `bareEmail`, which took the **last** `<…>` pair in
/// the header. That is not a mailbox parse, and the two sides of the comparison
/// were produced by different code, so a `From` this parser read differently
/// from a mail client wrote a wrong value into FROZEN frontmatter.
///
/// Both sides of that comparison now go through `canonical` — the property
/// #316's design claimed but did not enforce.
///
/// This is deliberately **not** a complete RFC 5322 implementation. It is a
/// conservative reduction of a mailbox to a comparable bare address, and it
/// prefers returning `nil` over returning a guess: a `nil` makes the caller
/// disclose (`direction_inferred: true`), which is the honest outcome, whereas
/// a wrong bare address is a confident wrong answer written to disk.
public enum EmailAddress {

    /// Reduce an address field to one lowercased bare address, or `nil` when it
    /// does not contain one.
    ///
    /// The field may be a list; the FIRST mailbox wins. RFC 5322 permits
    /// several authors in `From`, and the first is the primary one — taking the
    /// last is what archived a user's own co-authored message as `received`.
    public static func canonical(_ raw: String) -> String? {
        let firstMailbox = splitTopLevel(raw, separator: ",").first ?? ""
        // Reject structurally broken input rather than tidying it into
        // something that looks parsed (#343 verify): `strippingComments` will
        // happily swallow a `)` that never had an opener, so `user@x.com)`
        // used to canonicalise to `user@x.com` and could produce a confident
        // `sent`. A malformed `From` must reach the disclosure path.
        guard !hasUnbalancedDelimiters(firstMailbox) else { return nil }
        let withoutComments = strippingComments(firstMailbox)

        // Prefer the angle-addr when one exists at top level. FIRST, not last:
        // a trailing RFC comment may itself contain `<…>`, and taking the last
        // pair let that comment supply the address.
        let candidate: String
        if let angle = firstTopLevelAngleAddr(withoutComments) {
            candidate = angle
        } else {
            candidate = withoutComments
        }

        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAddressShaped(trimmed) else { return nil }
        return trimmed.lowercased()
    }

    /// One configured mailbox, with no dropped list entries or trailing data.
    /// Keeps canonical()'s addr-spec shaping; general From parsing is unchanged.
    public static func singleCanonical(_ raw: String) -> String? {
        guard !raw.unicodeScalars.contains(where: {
            ($0.value < 32 && $0.value != 9) || (127...159).contains($0.value)
                || $0.value == 0x2028 || $0.value == 0x2029
        }), let uncommented = configuredWithoutComments(raw) else { return nil }
        let clean = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = clean.unicodeScalars
        var quoted = false, escaped = false
        var openedAt: String.UnicodeScalarView.Index?
        var closedAt: String.UnicodeScalarView.Index?
        for index in scalars.indices {
            let scalar = scalars[index]
            if escaped { escaped = false; continue }
            if scalar == "\\" {
                guard quoted else { return nil }
                escaped = true
                continue
            }
            if scalar == "\"" { quoted.toggle(); continue }
            if quoted { continue }
            switch scalar {
            case ",", ";": return nil
            case "<":
                guard openedAt == nil else { return nil }
                openedAt = index
            case ">":
                guard openedAt != nil, closedAt == nil else { return nil }
                closedAt = index
            default: break
            }
        }
        guard !quoted, !escaped else { return nil }
        let candidate: String
        if let openedAt {
            guard let closedAt,
                  String(scalars[scalars.index(after: closedAt)...]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  configuredDisplayNameIsValid(String(scalars[..<openedAt])) else { return nil }
            candidate = String(scalars[scalars.index(after: openedAt)..<closedAt])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            candidate = clean
        }
        let comparable = configuredAddressWithoutCFWS(candidate)
        guard isAddressShaped(comparable) else { return nil }
        return comparable.lowercased()
    }

    /// CFWS can surround addr-spec separators; it cannot join two atom words.
    private static func configuredAddressWithoutCFWS(_ raw: String) -> String {
        let input = Array(raw.unicodeScalars)
        var output = String.UnicodeScalarView()
        var quoted = false, escaped = false
        var index = 0
        while index < input.count {
            let scalar = input[index]
            if escaped { output.append(scalar); escaped = false; index += 1; continue }
            if scalar == "\\" { escaped = true }
            else if scalar == "\"" { quoted.toggle() }
            if !quoted && (scalar == " " || scalar == "\t") {
                var end = index + 1
                while end < input.count && (input[end] == " " || input[end] == "\t") { end += 1 }
                let previous = output.last
                let next = end < input.count ? input[end] : nil
                if previous != "@" && previous != "." && next != "@" && next != "." {
                    output.append(contentsOf: input[index..<end])
                }
                index = end
            } else {
                output.append(scalar)
                index += 1
            }
        }
        return String(output)
    }

    /// Quotes and angles inside a comment are data, not mailbox delimiters.
    private static func configuredWithoutComments(_ raw: String) -> String? {
        var output = String.UnicodeScalarView()
        var depth = 0
        var quoted = false, escaped = false
        for scalar in raw.unicodeScalars {
            if depth > 0 {
                if escaped { escaped = false }
                else if scalar == "\\" { escaped = true }
                else if scalar == "(" { depth += 1 }
                else if scalar == ")" { depth -= 1 }
                continue
            }
            if escaped { output.append(scalar); escaped = false; continue }
            if scalar == "\\" {
                guard quoted else { return nil }
                output.append(scalar)
                escaped = true
            } else if scalar == "\"" {
                quoted.toggle()
                output.append(scalar)
            } else if !quoted && scalar == "(" {
                depth = 1
                output.append(" ") // Never concatenate atoms across comments.
            } else if !quoted && scalar == ")" {
                return nil
            } else {
                output.append(scalar)
            }
        }
        guard depth == 0, !quoted, !escaped else { return nil }
        return String(output)
    }

    private static func configuredDisplayNameIsValid(_ name: String) -> Bool {
        let atom = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-/=?^_`{|}~.")
        var quoted = false, escaped = false
        for scalar in name.unicodeScalars {
            if escaped { escaped = false; continue }
            if scalar == "\\" {
                guard quoted else { return false }
                escaped = true
            } else if scalar == "\"" {
                quoted.toggle()
            } else if !quoted && scalar != " " && scalar != "\t"
                        && scalar.value < 128 && !atom.contains(scalar) {
                return false
            }
        }
        return !quoted && !escaped
    }

    /// EVERY mailbox in the field, canonicalised — for identity questions.
    ///
    /// #343's first fix took the FIRST mailbox because last-wins had archived a
    /// user's own co-authored message as `received`. The verify round pointed
    /// out that this only swapped which permutation breaks: with
    /// `Coauthor <them>, User <you>` the first mailbox is not the user, so the
    /// message was still confidently `received`.
    ///
    /// RFC 5322 does not privilege the first author — every mailbox in `From`
    /// IS an author. So identity asks "is ANY of them mine", while the display
    /// form below still shows one. (Whoever physically sent it is `Sender:`,
    /// a different header this does not read.)
    public static func allCanonical(_ raw: String) -> [String] {
        splitTopLevel(raw, separator: ",").compactMap { mailbox in
            let withoutComments = strippingComments(mailbox)
            guard !hasUnbalancedDelimiters(mailbox) else { return nil }
            let candidate = firstTopLevelAngleAddr(withoutComments) ?? withoutComments
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return isAddressShaped(trimmed) ? trimmed.lowercased() : nil
        }
    }

    /// A best-effort display form that never returns `nil` — used where a
    /// missing value would be worse than an imperfect one (filenames, the
    /// rendered `sender:` line). Falls back to the trimmed, lowercased input.
    public static func display(_ raw: String) -> String {
        canonical(raw) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Scanning

    /// True when parentheses or angle brackets do not pair up outside quotes.
    /// Quoted content is exempt: `"a)b"@host` is legal.
    private static func hasUnbalancedDelimiters(_ s: String) -> Bool {
        var inQuotes = false, escaped = false
        var paren = 0, angle = 0
        for c in s {
            if escaped { escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            switch c {
            case "(": paren += 1
            case ")": paren -= 1; if paren < 0 { return true }
            case "<": angle += 1
            case ">": angle -= 1; if angle < 0 { return true }
            default: break
            }
        }
        return paren != 0 || angle != 0 || inQuotes
    }

    /// Must hold exactly one `@` OUTSIDE any quoted string, with a non-empty
    /// local part and a domain containing no whitespace.
    ///
    /// The quoting rule is what keeps `"x<user@gmail.com>"@evil.example` intact:
    /// its quoted local part contains an `@`, so a naive count sees two and a
    /// naive split takes the wrong half.
    private static func isAddressShaped(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var inQuotes = false, escaped = false
        var atIndex: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if escaped { escaped = false; i = s.index(after: i); continue }
            switch c {
            case "\\" where inQuotes: escaped = true
            case "\"": inQuotes.toggle()
            case "@" where !inQuotes:
                if atIndex != nil { return false }   // two top-level @ — not one mailbox
                atIndex = i
            case " ", "\t", "\n", "\r":
                if !inQuotes { return false }        // whitespace outside quotes
            case "<", ">", "(", ")":
                if !inQuotes { return false }        // stray delimiter — not an addr-spec
            default: break
            }
            i = s.index(after: i)
        }
        guard let at = atIndex else { return false }
        let local = s[s.startIndex..<at]
        let domain = s[s.index(after: at)...]
        // A domain must contain a dot or be a bare host; require non-empty both
        // sides. `<>` (the null return-path) correctly falls out here.
        return !local.isEmpty && !domain.isEmpty
    }

    /// Split on a separator that appears outside quotes, angle brackets, and
    /// comments — so a comma inside `"Cheng, Che"` is not a list separator.
    private static func splitTopLevel(_ s: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false, escaped = false
        var angleDepth = 0, parenDepth = 0
        for c in s {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" { current.append(c); escaped = true; continue }
            if c == "\"" { inQuotes.toggle(); current.append(c); continue }
            if !inQuotes {
                if c == "<" { angleDepth += 1 }
                if c == ">" { angleDepth = max(0, angleDepth - 1) }
                if c == "(" { parenDepth += 1 }
                if c == ")" { parenDepth = max(0, parenDepth - 1) }
                if c == separator && angleDepth == 0 && parenDepth == 0 {
                    parts.append(current)
                    current = ""
                    continue
                }
            }
            current.append(c)
        }
        parts.append(current)
        return parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Remove RFC 5322 comments — parenthesised runs outside quotes, nesting
    /// allowed. A comment may legally contain anything, INCLUDING something
    /// that looks like an address; that is exactly the false-`sent` vector.
    private static func strippingComments(_ s: String) -> String {
        var out = ""
        var inQuotes = false, escaped = false
        var depth = 0
        for c in s {
            if escaped { if depth == 0 { out.append(c) }; escaped = false; continue }
            if c == "\\" { if depth == 0 { out.append(c) }; escaped = true; continue }
            if !inQuotes {
                if c == "(" { depth += 1; continue }
                if c == ")" { depth = max(0, depth - 1); continue }
            }
            if depth > 0 { continue }
            if c == "\"" { inQuotes.toggle() }
            out.append(c)
        }
        return out
    }

    /// Contents of the FIRST top-level `<…>`, or nil when there is none.
    private static func firstTopLevelAngleAddr(_ s: String) -> String? {
        var inQuotes = false, escaped = false
        var start: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if escaped { escaped = false; i = s.index(after: i); continue }
            if c == "\\" { escaped = true; i = s.index(after: i); continue }
            if c == "\"" { inQuotes.toggle(); i = s.index(after: i); continue }
            if !inQuotes {
                if c == "<", start == nil { start = s.index(after: i) }
                else if c == ">", let st = start { return String(s[st..<i]) }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
