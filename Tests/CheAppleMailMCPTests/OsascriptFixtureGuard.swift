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
        ("use statement", #"(^|[\n\r])\s*use\s"#),
        ("|…| identifier", #"\|"#),
    ]

    /// What `foundationBridge` still refuses by name: the classes that reach another application or
    /// run other code, and the ways to name a class in a string, which `code(of:)` empties. Any other
    /// Foundation class is data handling (#617).
    static let bridgeRefusals = #"\bNS(Workspace|AppleScript|Task|Process|RunningApplication|UserScriptTask|UserAppleScriptTask|UserUnixTask|UserAutomatorTask|AppleEventDescriptor|AppleEventManager|Bundle|Pasteboard|DistributedNotificationCenter|ConnectionToApplication|XPCConnection|ClassFromString|ProtocolFromString|SelectorFromString|Invocation)\b|\bSBApplication\b|\bperformSelector|\bvalueForKey|\bclass\s+"""#

    /// Throws `ApplicationReference` if the fragment could address an application.
    ///
    /// Both lists run against `code(of:)`: comments removed and every string literal emptied.
    /// Production scripts mention System Events in comments and in error messages, which cannot
    /// address anything; `application "Mail"` becomes `application ""` and is still refused.
    ///
    /// `foundationBridge` is for handlers that really use the AppleScript-Objective-C bridge. It lets
    /// through exactly `use framework "Foundation"`, `use scripting additions` and
    /// `current application`, and refuses the classes in `bridgeRefusals` instead (#617).
    static func check(_ fragment: String, foundationBridge: Bool = false) throws {
        var code = code(of: fragment)
        if foundationBridge {
            code = try removingFoundationBridge(from: code, fragment: fragment)
        }
        let lowered = code.lowercased()
        for pattern in textPatterns where lowered.contains(pattern) {
            throw ApplicationReference(pattern: pattern, fragment: fragment)
        }
        for (name, regex) in codePatterns
        where code.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil {
            throw ApplicationReference(pattern: name, fragment: fragment)
        }
    }

    private static func removingFoundationBridge(from code: String, fragment: String) throws -> String {
        if code.range(of: bridgeRefusals, options: [.regularExpression, .caseInsensitive]) != nil {
            throw ApplicationReference(pattern: "a Foundation class that reaches other code", fragment: fragment)
        }
        // Literals are emptied in `code`, so the framework's name is read from the same lexer with
        // literals kept. The raw fragment would disagree with `code` about comments and `¬`: a
        // `use (* x *) framework "AppKit"` is no `use framework` line there (#617 verify).
        let lines = Self.code(of: fragment, keepingLiterals: true).components(separatedBy: CharacterSet.newlines)
        for line in lines where line.range(of: #"^\s*use\s+framework\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            guard line.range(of: #"^\s*use\s+framework\s+"Foundation"\s*$"#, options: .regularExpression) != nil else {
                throw ApplicationReference(pattern: "a framework other than Foundation", fragment: fragment)
            }
        }
        return code
            // Bridge calls put keyword-like names in pipes (`… |error|:missing value`, `… |set|()`). A
            // plain word between pipes has no escape, quote or comment marker for the lexer to misread.
            .replacingOccurrences(of: #"\|[A-Za-z_][A-Za-z0-9_]*\|"#, with: "pipedName", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^[ \t]*use[ \t]+framework[ \t]+""[ \t]*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^[ \t]*use[ \t]+scripting[ \t]+additions[ \t]*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\bcurrent[ \t]+application\b"#, with: "currentBridge", options: .regularExpression)
    }

    /// For a test that replaced a GUI handler's statements with fixtures and calls that handler: its
    /// `tell` lines stay as a structure, pointed at `me`.
    static func pointingTellsAtMe(_ source: String) -> String {
        source
            .replacingOccurrences(of: #"tell application "[^"]*""#, with: "tell me", options: .regularExpression)
            .replacingOccurrences(of: #"tell process "[^"]*""#, with: "tell me", options: .regularExpression)
    }

    /// For a test that calls one pure handler of a file that also holds handlers it never calls: drops
    /// each `tell application …` block, so the text that runs has no way to reach an application and
    /// `check` can read all of it. A called handler that needed such a block fails its own test.
    /// A one-line `tell application "X" to …` stays, and `check` refuses it.
    static func neutralisingApplicationBlocks(_ source: String) -> String {
        var kept: [String] = []
        var depth = 0
        for line in source.components(separatedBy: "\n") {
            let code = line.trimmingCharacters(in: .whitespaces)
            if depth == 0 {
                if code.hasPrefix("tell application "), !code.contains(" to ") { depth = 1; continue }
                kept.append(line)
                continue
            }
            if code.hasPrefix("tell "), !code.contains(" to ") { depth += 1 }
            if code == "end tell" { depth -= 1 }
        }
        return kept.joined(separator: "\n")
    }

    /// The fragment with `--` and `#` line comments and `(* … *)` block comments (nested) removed,
    /// and the content of every `"…"` literal removed (the quotes stay), honouring `\"` and `\\`.
    /// A `|` is copied as written and `check` refuses it: a `|…|` identifier has escapes of its own,
    /// so lexing it here could only disagree with AppleScript about where it ends, and no fixture
    /// needs one (#572 verify, rounds 1 and 2). A `¬` continuation and its line break become one
    /// space, so `do ¬⏎ shell script` is still seen as `do shell script`. `keepingLiterals` keeps what
    /// is inside the quotes, for the one caller that has to read a name there.
    ///
    /// Works on Unicode scalars, not `Character`s: Swift treats `\r\n` as ONE `Character`, so a
    /// `Character` loop never sees the `\r` or `\n` that ends a comment and swallows every later line
    /// (#572 verify).
    static func code(of text: String, keepingLiterals: Bool = false) -> String {
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
                    if chars[i] == "\\" {
                        if keepingLiterals { out.append(contentsOf: chars[i..<min(i + 2, chars.count)]) }
                        i += 2
                        continue
                    }
                    if chars[i] == "\"" { out.append("\""); i += 1; break }
                    if keepingLiterals { out.append(chars[i]) }
                    i += 1
                }
                continue
            }
            out.append(c); i += 1
        }
        return String(out)
    }
}
