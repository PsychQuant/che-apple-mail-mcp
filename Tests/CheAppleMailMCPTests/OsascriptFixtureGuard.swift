import Foundation

/// #572: the check the osascript fixtures run on the exact text they hand to `/usr/bin/osascript`
/// (the list of files grew in #617). Unit tests must not reach Mail or System Events, and AppleScript can
/// address an application without the literal `tell application`: `tell app "Mail"`,
/// `… of application "Mail"`, `activate application "Mail"`, `application id "…"`,
/// `tell process "Mail"`, or indirectly through `run script` / `do shell script`.
///
/// What it defends against: a fixture written by mistake, one that keeps a line of a production
/// script or picks up another way of addressing an application. It does not defend against an author
/// trying to get past it, so the answer to a bypass that takes deliberate effort is not a longer list.
///
/// `bridgeNames` and `bridgePipedWords` are closed: nothing else of those shapes passes. Everything
/// else here is a deny list of the forms known to reach an application, not a proof that none can,
/// and that includes `bridgeRefusals`, which lists methods. It is deliberately broader than the code
/// it guards: a false positive only fails a test, which is the safe direction; a false negative sends
/// a real Apple Event from `swift test`.
enum OsascriptFixtureGuard {
    struct ApplicationReference: Error, CustomStringConvertible {
        let pattern: String
        let fragment: String
        var description: String { "fixture fragment refers to an application or escapes the interpreter (\(pattern)); refusing to run it" }
    }

    /// Word checks against the code only, ignoring case. #572 first listed the strings `application "`,
    /// `app "`, `process "` and `System Events` too. They added nothing that compiles: the first three
    /// are these words with a quote after them, and `System Events` is only ever a literal, which
    /// `code(of:)` empties, so it was dropped (#572 verify).
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

    /// The only class-shaped names `foundationBridge` lets through: the ones the handlers under test
    /// use. It is a closed list because a list of dangerous classes has to be right about every
    /// class: `NSExpression` runs a format string that can name `NSTask`, and AppKit is already linked
    /// into osascript, so `use framework "Foundation"` does not limit what resolves (#617 verify).
    /// A handler that needs another name adds it here, with a reviewer's eye on what it can reach.
    static let bridgeNames: Set<String> = [
        "NSCharacterSet", "NSData", "NSDate", "NSJSONSerialization", "NSMutableArray", "NSMutableDictionary",
        "NSMutableSet", "NSNotFound", "NSPredicate", "NSString", "NSUTF8StringEncoding",
    ]

    /// The words the handlers under test put in pipes, a closed list like `bridgeNames`: the plain-word
    /// shape would also erase `|application|` and `|process|` from the word checks (#617 verify).
    static let bridgePipedWords = ["date", "error", "set"]

    /// Any `NS…` word in either case, or the shape of an Objective-C class of another prefix
    /// (`SBApplication`, `OSAScript`).
    static let classShaped = #"\b(?:[Nn][Ss][A-Za-z0-9_]*|[A-Z]{2,}[a-z0-9][A-Za-z0-9_]*)\b"#

    /// What reaches code by a name in a string, on any receiver, and any `class` other than
    /// `class of x`: `class "NSTask"` and `class ("NS" & "Task")` name one at run time.
    static let bridgeRefusals = #"Selector|valueForKey|\bclass\b(?!\s+of\b)"#

    /// `NSPredicate` evaluates `FUNCTION` and `CAST` in its format string, so it is let through only
    /// for the one format the handlers use, as the whole argument: the next label has to follow the
    /// literal, or `"SELF MATCHES %@" & x` would pass with its tail unread (#617 verify).
    static let bridgePredicate = #"NSPredicate's predicateWithFormat:"SELF MATCHES %@" argumentArray:"#

    /// Throws `ApplicationReference` if the fragment could address an application.
    ///
    /// The word checks run against `code(of:)`: comments removed and every string literal emptied. The
    /// bridge's predicate and framework checks read the same lexer with literals kept.
    /// Production scripts mention System Events in comments and in error messages, which cannot
    /// address anything; `application "Mail"` becomes `application ""` and is still refused.
    ///
    /// `foundationBridge` is for handlers that really use the AppleScript-Objective-C bridge. It lets
    /// through exactly `use framework "Foundation"`, `use scripting additions`, the names in
    /// `bridgeNames`, `current application's` before one of them, and the words in `bridgePipedWords`
    /// (#617). That bounds the class names a fixture can write, not what the methods of those classes
    /// do or return: `NSData` and `NSString` can read and write files and fetch URLs. No way from them
    /// to another application is known.
    static func check(_ fragment: String, foundationBridge: Bool = false) throws {
        var code = code(of: fragment)
        if foundationBridge {
            code = try removingFoundationBridge(from: code, fragment: fragment)
        }
        for (name, regex) in codePatterns
        where code.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil {
            throw ApplicationReference(pattern: name, fragment: fragment)
        }
    }

    private static func removingFoundationBridge(from code: String, fragment: String) throws -> String {
        if code.range(of: bridgeRefusals, options: [.regularExpression, .caseInsensitive]) != nil {
            throw ApplicationReference(pattern: "a name that reaches other code", fragment: fragment)
        }
        var rest = code[...]
        while let range = rest.range(of: classShaped, options: .regularExpression) {
            let name = String(rest[range])
            guard bridgeNames.contains(name) else {
                throw ApplicationReference(pattern: "\(name) is not in bridgeNames", fragment: fragment)
            }
            rest = rest[range.upperBound...]
        }
        // Literals are emptied in `code`, so what has to be read inside them comes from the same lexer
        // with literals kept. The raw fragment would disagree with `code` about comments and `¬`: a
        // `use (* x *) framework "AppKit"` is no `use framework` line there (#617 verify).
        let kept = Self.code(of: fragment, keepingLiterals: true)
        if kept.replacingOccurrences(of: bridgePredicate, with: "").range(of: "predicate", options: .caseInsensitive) != nil {
            throw ApplicationReference(pattern: "a predicate other than \(bridgePredicate)", fragment: fragment)
        }
        for line in kept.components(separatedBy: CharacterSet.newlines)
        where line.range(of: #"^\s*use\s+framework\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            guard line.range(of: #"^\s*use\s+framework\s+"Foundation"\s*$"#, options: .regularExpression) != nil else {
                throw ApplicationReference(pattern: "a framework other than Foundation", fragment: fragment)
            }
        }
        // Any other `current application` stays in the text, and the `application` check refuses it.
        let names = bridgeNames.sorted().joined(separator: "|")
        return code
            // Bridge calls put keyword-like names in pipes (`… |error|:missing value`, `… |set|()`).
            .replacingOccurrences(of: "\\|(\(bridgePipedWords.joined(separator: "|")))\\|", with: "pipedName", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^[ \t]*use[ \t]+framework[ \t]+""[ \t]*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^[ \t]*use[ \t]+scripting[ \t]+additions[ \t]*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\bcurrent[ \\t]+application's[ \\t]+(\(names))\\b", with: "$1", options: .regularExpression)
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
    /// A one-line `tell application "X" to …` stays, and `check` refuses it. So does a `tell` line
    /// with a `¬`, which may be a one-line tell carried over.
    ///
    /// It reads line by line, each through `code(of:)`, so a trailing comment or a literal does not
    /// change what a line is. A block that never closes throws instead of dropping the rest of the
    /// text: that used to run a truncated script with nothing refused, and the handler under test
    /// never ran (#617 verify). A comment or literal spanning lines is not followed; a miscount there
    /// leaves a block open or a stray `end tell`, which throws or does not compile.
    static func neutralisingApplicationBlocks(_ source: String) throws -> String {
        var kept: [String] = []
        var depth = 0
        for line in source.components(separatedBy: "\n") {
            let code = code(of: line).trimmingCharacters(in: .whitespaces)
            if depth == 0 {
                if code.hasPrefix("tell application "), !code.contains(" to "), !line.contains("¬") { depth = 1; continue }
                kept.append(line)
                continue
            }
            if code.hasPrefix("tell "), !code.contains(" to ") { depth += 1 }
            if code == "end tell" { depth -= 1 }
        }
        guard depth == 0 else {
            throw ApplicationReference(pattern: "a tell block that never closes", fragment: source)
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
