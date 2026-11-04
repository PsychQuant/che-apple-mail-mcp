import Foundation

/// #572: the one check every test runs before it hands a fragment cut out of a production script
/// to `/usr/bin/osascript`. Unit tests must not reach Mail or System Events, and AppleScript can
/// address an application without the literal `tell application`: `tell app "Mail"`,
/// `… of application "Mail"`, `activate application "Mail"`, `application id "…"`,
/// `tell process "Mail"`, or indirectly through `run script` / `do shell script`.
///
/// The check is deliberately broader than the code it guards. A false positive only fails a test,
/// which is the safe direction; a false negative sends a real Apple Event from `swift test`.
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
    /// `|…|` identifiers are kept as written, which can only make the check stricter.
    static func code(of text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        var blockDepth = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
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
        return out
    }
}
