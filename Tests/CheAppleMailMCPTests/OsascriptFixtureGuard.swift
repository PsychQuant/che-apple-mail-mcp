import Foundation

/// #572: the check the osascript fixtures in `ComposeCleanupSheetTests` and
/// `PostIdentificationCleanupTests` run on the exact text they hand to `/usr/bin/osascript`
/// (other fixtures still use their own literal checks; #617). Unit tests must not reach Mail or System Events, and AppleScript can
/// address an application without the literal `tell application`: `tell app "Mail"`,
/// `… of application "Mail"`, `activate application "Mail"`, `application id "…"`,
/// `tell process "Mail"`, or indirectly through `run script` / `do shell script`.
///
/// It is a deny list of the forms known to reach an application, not a proof that none can. It is
/// deliberately broader than the code it guards: a false positive only fails a test, which is the
/// safe direction; a false negative sends a real Apple Event from `swift test`.
enum OsascriptFixtureGuard {
    struct ApplicationReference: Error, CustomStringConvertible {
        let pattern: String
        let fragment: String
        var description: String { "fixture fragment refers to an application or escapes the interpreter (\(pattern)); refusing to run it" }
    }

    /// The list from #572's Expected (case-insensitive), matched against the code only.
    static let textPatterns = ["application \"", "app \"", "system events", "process \""]

    /// Word checks, also against the code only.
    static let codePatterns: [(name: String, regex: String)] = [
        ("application / app", #"\bapp(lication)?\b"#),
        ("process", #"\bprocess(es)?\b"#),
        ("raw event code «…»", "«"),
        ("run script", #"\brun\s+script\b"#),
        ("do shell script", #"\bdo\s+shell\s+script\b"#),
        ("load script", #"\bload\s+script\b"#),
        ("store script", #"\bstore\s+script\b"#),
        ("open location", #"\bopen\s+location\b"#),
        ("use statement", #"(^|\n)\s*use\s"#),
    ]

    /// Throws `ApplicationReference` if the fragment could address an application.
    ///
    /// Both lists run against `code(of:)`: comments removed and every string literal emptied.
    /// Production scripts mention System Events in comments and in error messages, which cannot
    /// address anything; `application "Mail"` becomes `application ""` and is still refused.
    static func check(_ fragment: String) throws {
        let code = code(of: fragment)
        let lowered = code.lowercased()
        for pattern in textPatterns where lowered.contains(pattern) {
            throw ApplicationReference(pattern: pattern, fragment: fragment)
        }
        for (name, regex) in codePatterns
        where code.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil {
            throw ApplicationReference(pattern: name, fragment: fragment)
        }
    }

    /// The fragment with `--` and `#` line comments and `(* … *)` block comments (nested) removed,
    /// and the content of every `"…"` literal removed (the quotes stay), honouring `\"` and `\\`.
    /// A `|…|` identifier is copied as written, and a quote or comment marker inside it does not
    /// start a literal or a comment (it does not in AppleScript either). A `¬` continuation and its
    /// line break become one space, so `do ¬⏎ shell script` is still seen as `do shell script`.
    ///
    /// Works on Unicode scalars, not `Character`s: Swift treats `\r\n` as ONE `Character`, so a
    /// `Character` loop never sees the `\r` or `\n` that ends a comment and swallows every later line
    /// (#572 verify).
    static func code(of text: String) -> String {
        let chars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        var blockDepth = 0
        while i < chars.count {
            let c = chars[i]
            let next: Unicode.Scalar? = i + 1 < chars.count ? chars[i + 1] : nil
            if blockDepth > 0 {
                if c == "(" && next == "*" { blockDepth += 1; i += 2; continue }
                if c == "*" && next == ")" { blockDepth -= 1; i += 2; out.append(" "); continue }
                i += 1; continue
            }
            if c == "(" && next == "*" { blockDepth = 1; i += 2; continue }
            if (c == "-" && next == "-") || c == "#" {
                while i < chars.count && chars[i] != "\n" && chars[i] != "\r" { i += 1 }
                continue
            }
            if c == "|" {
                out.append(c); i += 1
                while i < chars.count {
                    out.append(chars[i]); i += 1
                    if chars[i - 1] == "|" { break }
                }
                continue
            }
            if c == "¬" {
                i += 1
                if i < chars.count && chars[i] == "\r" { i += 1 }
                if i < chars.count && chars[i] == "\n" { i += 1 }
                out.append(" ")
                continue
            }
            if c == "\"" {
                out.append(c); i += 1
                while i < chars.count {
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == "\"" { out.append("\""); i += 1; break }
                    i += 1
                }
                continue
            }
            out.append(c); i += 1
        }
        return String(out)
    }
}
