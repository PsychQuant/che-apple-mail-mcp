import XCTest
@testable import CheAppleMailMCP

/// #490 — guard tests for `.claude/rules/direct-write-transaction-safety.md`.
/// Each test pins one guarantee of that rule so that a speed change which
/// weakens it turns the suite red instead of shipping silently.
///
/// These are STRUCTURAL checks of the trigger script and of the Swift source,
/// not behavioural tests (those need the controller/writer seam of #484). The
/// rule lists exactly which edits they catch; anything outside that list is not
/// guarded, however similar it looks.
///
/// - Item 8: the gap between the two read toggles of the upload trigger is a
///   safety margin known to work, not a known floor (0.5 s; #472 saw 0.3 s
///   leave one of two drafts unread locally). Changing it needs the live
///   experiment of #488 first.
/// - Item 7: after an accepted trigger the path waits for the upload to be
///   confirmed and then re-asserts the draft's read status (#482).
final class DirectWriteSafetyGuardTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func directDraftPathSource() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("Sources/CheAppleMailMCP/DirectDraft/DirectDraftPath.swift"),
                   encoding: .utf8)
    }

    private static let hint = " (if a refactor moved this, replace the check with a behavioural test once #484 adds the seam)"

    // MARK: - Item 8: the gap between the read toggles

    static let minimumToggleGap: Double = 0.5

    enum ToggleGap: Equatable {
        case seconds(Double)
        case unverifiable(String)
    }

    /// The total of the `delay` statements between the toggle to unread and
    /// the toggle back to read, after AppleScript comments are removed. A
    /// script the parser cannot read with certainty is reported as
    /// unverifiable, never as a number: a `delay` whose argument is not a plain
    /// number literal on its own line could hide any value, control flow could
    /// skip a delay, and a second toggle pair would make "the gap" ambiguous.
    static func toggleGap(in script: String) -> ToggleGap {
        // String contents are blanked so a `delay` inside a string literal is
        // not counted, and every read-status toggle is counted in any case or
        // on any variable (round 3).
        let code = strippingAppleScriptComments(script, blankingStrings: true)
        let anyToggle = matches(of: #"\bset\s+read\s+status\s+of\b"#, in: code, caseInsensitive: true).count
        guard anyToggle == 2 else {
            return .unverifiable("expected exactly two read-status toggles, found \(anyToggle)")
        }
        let toUnread = ranges(of: "set read status of _m to false", in: code)
        let toRead = ranges(of: "set read status of _m to true", in: code)
        guard toUnread.count == 1, toRead.count == 1 else {
            return .unverifiable("expected one toggle to unread and one back to read, "
                                 + "found \(toUnread.count) and \(toRead.count)")
        }
        guard toUnread[0].upperBound <= toRead[0].lowerBound else {
            return .unverifiable("the toggle back to read comes before the toggle to unread")
        }
        let between = String(code[toUnread[0].upperBound..<toRead[0].lowerBound])
        // AppleScript keywords are case-insensitive (Round 2).
        let controlFlow = #"^\s*(if|repeat|try|considering|ignoring|tell|with|using|on|error|return|exit|end)\b"#
        guard matches(of: controlFlow, in: between, caseInsensitive: true).isEmpty else {
            return .unverifiable("control flow between the toggles: the parser cannot tell whether a delay runs")
        }
        let delayCount = matches(of: #"\bdelay\b"#, in: between, caseInsensitive: true).count
        let literals = matches(of: #"^\s*delay\s+([0-9]+(?:\.[0-9]+)?)\s*$"#, in: between, caseInsensitive: true)
            .compactMap { Double($0) }
        guard delayCount == literals.count else {
            return .unverifiable("a delay between the toggles is not a plain number literal on its own line")
        }
        return .seconds(literals.reduce(0, +))
    }

    func testTriggerScriptKeepsTheMeasuredGapBetweenItsReadToggles() {
        let script = buildDirectDraftTriggerScript(rowId: 305619)
        switch Self.toggleGap(in: script) {
        case .seconds(let gap):
            XCTAssertGreaterThanOrEqual(
                gap, Self.minimumToggleGap,
                "rule item 8: the read-toggle gap is a margin known to work, not a known floor (#472 saw 0.3 s leave "
                + "a draft unread locally). Shortening it needs the #488 live experiment, at least 10 runs per value.")
        case .unverifiable(let why):
            XCTFail("rule item 8: the trigger script's read-toggle gap cannot be verified: \(why)")
        }
    }

    /// The parser reads what it claims to: each counter-example is a script
    /// whose gap is too short, or hidden, and must not pass.
    func testToggleGapParserRejectsShortOrHiddenGaps() {
        func script(_ middle: String, before: String = "") -> String {
            "tell application \"Mail\"\n\(before)    set read status of _m to false\n\(middle)"
                + "    set read status of _m to true\nend tell\n"
        }
        XCTAssertEqual(Self.toggleGap(in: script("    delay 0.5\n")), .seconds(0.5))
        XCTAssertEqual(Self.toggleGap(in: script("    delay 0.5 -- the #463 gap\n")), .seconds(0.5))
        XCTAssertEqual(Self.toggleGap(in: script("    delay 0.3\n")), .seconds(0.3), "the gap #472 saw fail")
        XCTAssertEqual(Self.toggleGap(in: script("    delay 0.2\n    log \"x\"\n    delay 0.2\n")), .seconds(0.4),
                       "split delays are summed")
        XCTAssertEqual(Self.toggleGap(in: script("    my _cheMailMark(\"trigger_unread\")\n    delay 0.5\n")),
                       .seconds(0.5), "a timing mark (#489) between the toggles is not a delay")
        XCTAssertEqual(Self.toggleGap(in: script("", before: "    delay 0.5\n")), .seconds(0),
                       "a delay outside the toggles does not count")
        // Round 1: an old value kept in a comment is not a delay.
        XCTAssertEqual(Self.toggleGap(in: script("    (*\n    delay 0.5\n    *)\n    delay 0.3\n")), .seconds(0.3))
        XCTAssertEqual(Self.toggleGap(in: script("    delay 0.3 (* was 0.5 *)\n")), .seconds(0.3))
        XCTAssertEqual(Self.toggleGap(in: script("    -- delay 0.5\n    delay 0.3\n")), .seconds(0.3))
        XCTAssertEqual(Self.toggleGap(in: script("    # delay 0.5\n    delay 0.3\n")), .seconds(0.3))
        XCTAssertEqual(Self.toggleGap(in: script("    Delay 0.3\n")), .seconds(0.3), "AppleScript is case-insensitive")
        // Round 3: a `delay` inside a multi-line string literal does not run.
        XCTAssertEqual(Self.toggleGap(in: script("    set s to \"x\n    delay 0.9\n    \"\n    delay 0.1\n")), .seconds(0.1))
        for hidden in ["    delay gapSeconds\n", "    delay (0.5)\n", "    delay 1 / 4\n",
                       // Round 1: a delay that may never run.
                       "    if false then\n    delay 0.5\n    end if\n",
                       "    repeat 0 times\n    delay 0.5\n    end repeat\n",
                       "    try\n    delay 0.5\n    end try\n",
                       // Round 2: keywords in any case.
                       "    If false then\n    delay 0.5\n    End If\n",
                       "    REPEAT 0 TIMES\n    delay 0.5\n    END REPEAT\n",
                       // Round 3: a third toggle in another case or on another variable.
                       "    delay 0.5\n    SET READ STATUS OF _m TO TRUE\n",
                       "    delay 0.5\n    set read status of _x to true\n"] {
            guard case .unverifiable = Self.toggleGap(in: script(hidden)) else {
                return XCTFail("a hidden or conditional delay must be unverifiable: \(hidden)")
            }
        }
        let twoPairs = script("    delay 0.5\n") + script("    delay 0.1\n")
        guard case .unverifiable = Self.toggleGap(in: twoPairs) else {
            return XCTFail("two toggle pairs make the gap ambiguous")
        }
    }

    // MARK: - Item 7: upload confirmation and read repair

    /// The post-trigger section of `attemptSteps`, from the `inserted` mark to
    /// the function's closing brace, as code lines (comments removed,
    /// whitespace trimmed). FROZEN: any added, removed, changed, reordered or
    /// commented-out line turns the test red. Round 2 showed that checking
    /// fragments of this section invites one bypass per insertion point (an
    /// inline early return, a `break` inside the loop, a shifted clock), so the
    /// whole section is pinned instead; round 3 showed the ends need pinning
    /// too (a wrapper opened before the section and closed after it), so the
    /// copy runs to the closing brace and the next line must start a new
    /// declaration. An edit here (e.g. #489's timing marks) updates this copy in
    /// the same commit, and the reviewer checks it against rule items 2, 3, 6
    /// and 7.
    static let frozenPostTrigger = #"""
        timer.mark("inserted")
        let triggered = Date()
        do {
        _ = try await controller.triggerDirectDraftUpload(rowId: inserted.messageRowId)
        timer.mark("trigger_sent")
        } catch {
        let triggerError = error.localizedDescription
        do {
        try writer.rollback(inserted)
        return Self.outcomeAfterFailedTrigger(rollbackError: nil, triggerError: triggerError)
        } catch {
        return Self.outcomeAfterFailedTrigger(rollbackError: error, triggerError: triggerError)
        }
        }
        while Date().timeIntervalSince(triggered) < uploadDeadline {
        let state = writer.uploadState(inserted)
        if state.remoteId != nil && !state.actionQueued {
        let seconds = Date().timeIntervalSince(triggered)
        timer.mark("uploaded")
        let read = await ensureRead(writer, inserted)
        if read == .confirmed { timer.mark("read_ensured") }
        return .created(Self.createdText(seconds: seconds, uploaded: true) + read.note, pending: false)
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return .created(Self.createdText(seconds: uploadDeadline, uploaded: false), pending: true)
        }
        """#

    /// `ensureRead`, whole function. FROZEN like the section above: the probe
    /// counts, the unread gate and the re-assert are all part of the read
    /// repair (#482).
    static let frozenEnsureRead = #"""
        private func ensureRead(_ writer: DraftStoreWriter, _ inserted: DraftStoreWriter.Inserted) async -> ReadOutcome {
        var looks: [Bool?] = []
        for attempt in 0..<4 {
        let flag = writer.readFlag(inserted)
        looks.append(flag)
        if flag != nil { break }
        if attempt < 3 { try? await Task.sleep(nanoseconds: 250_000_000) }
        }
        let first = Self.readOutcome(looks)
        guard first == .stillUnread else { return first }
        _ = try? await controller.markDirectDraftRead(rowId: inserted.messageRowId)
        var after: [Bool?] = []
        for _ in 0..<8 {
        let flag = writer.readFlag(inserted)
        after.append(flag)
        if flag == true { break }
        try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return Self.readOutcome(after)
        }
        """#

    /// The only code lines that may name what the frozen sections call or are
    /// called from: the declaration and the one call. A local closure named
    /// `ensureRead` declared before the section would shadow the method and
    /// skip the read repair; a copied `attemptSteps` could take over the call
    /// and leave the frozen original unused (round 3).
    static let pinnedNameLines: [(name: String, lines: [String])] = [
        ("ensureRead", [
            "let read = await ensureRead(writer, inserted)",
            "private func ensureRead(_ writer: DraftStoreWriter, _ inserted: DraftStoreWriter.Inserted) async -> ReadOutcome {",
        ]),
        ("attemptSteps(", [
            "let outcome = await attemptSteps(to: to, subject: subject, body: body, cc: cc, bcc: bcc,",
            "private func attemptSteps(to: [String], subject: String, body: String, cc: [String]?, bcc: [String]?,",
        ]),
    ]

    /// A frozen section must be followed by the start of another declaration,
    /// so nothing can be appended after its closing brace.
    static let declarationStarts = ["func ", "static func ", "private func ", "private static func ",
                                    "fileprivate func ", "fileprivate static func ", "@"]

    /// How `source` (DirectDraftPath.swift) departs from the item 7 shape;
    /// empty when it holds.
    static func itemSevenViolations(in source: String) -> [String] {
        let lines = codeLines(of: source)
        var problems: [String] = []
        for pinned in pinnedNameLines {
            let found = lines.filter { $0.contains(pinned.name) }
            if found.sorted() != pinned.lines.sorted() {
                problems.append("`\(pinned.name)` appears on lines other than its declaration and its one call: \(found)")
            }
        }
        var postTrigger: Range<Int>?
        for (name, frozen) in [("post-trigger section of attemptSteps", frozenPostTrigger), ("ensureRead", frozenEnsureRead)] {
            switch frozenMatch(name, expected: codeLines(of: frozen), in: lines) {
            case .mismatch(let message):
                problems.append(message)
            case .match(let range):
                let next = range.upperBound < lines.count ? lines[range.upperBound] : "<end of file>"
                if !declarationStarts.contains(where: { next.hasPrefix($0) }) {
                    problems.append("\(name): the line after its closing brace is `\(next)`, not a new declaration")
                }
                if postTrigger == nil { postTrigger = range }
            }
        }
        if let section = postTrigger,
           let declaration = lines.firstIndex(where: { $0.hasPrefix("private func attemptSteps(") }) {
            let between = lines[(declaration + 1)..<max(declaration + 1, section.lowerBound)]
            if declaration > section.lowerBound || between.contains(where: { $0.contains("func ") }) {
                problems.append("the post-trigger section is not inside attemptSteps")
            }
        }
        return problems
    }

    enum FrozenMatch {
        case match(Range<Int>)
        case mismatch(String)
    }

    /// Where `expected` sits in `actual`, starting at the single occurrence of
    /// its first line, or the first difference.
    private static func frozenMatch(_ name: String, expected: [String], in actual: [String]) -> FrozenMatch {
        let starts = actual.indices.filter { actual[$0] == expected[0] }
        guard starts.count == 1, let start = starts.first else {
            return .mismatch("\(name): its first line `\(expected[0])` occurs \(starts.count) times (expected once)")
        }
        for (offset, want) in expected.enumerated() {
            let index = start + offset
            let got = index < actual.count ? actual[index] : "<end of file>"
            if got != want {
                return .mismatch("\(name), line \(offset + 1): expected `\(want)`, found `\(got)`")
            }
        }
        return .match(start..<(start + expected.count))
    }

    func testUploadIsConfirmedThenReadRepairedAfterAnAcceptedTrigger() throws {
        let problems = Self.itemSevenViolations(in: try Self.directDraftPathSource())
        XCTAssertEqual(problems, [], "rule item 7: " + problems.joined(separator: "; ")
                       + " — if this edit is intended, update the frozen copy in this file and check it against rule "
                       + "items 2, 3, 6 and 7")
    }

    /// Each edit a reviewer showed passing an earlier version of this guard
    /// (rounds 1 and 2), applied to the real source in memory, must be caught.
    func testItemSevenCheckCatchesTheEditsReviewersFound() throws {
        let source = try Self.directDraftPathSource()
        let edits: [(name: String, find: String, replace: String)] = [
            // Round 1
            ("read repair call commented out", "let read = await ensureRead(writer, inserted)",
             "// let read = await ensureRead(writer, inserted)"),
            ("read repair call in a block comment", "let read = await ensureRead(writer, inserted)",
             "/* let read = await ensureRead(writer, inserted) */"),
            ("upload condition loosened", "if state.remoteId != nil && !state.actionQueued {",
             "if state.remoteId != nil && !state.actionQueued || true {"),
            ("wait scaled down", "< uploadDeadline {", "< uploadDeadline / 10 {"),
            ("wait detached", "while Date().timeIntervalSince(triggered) < uploadDeadline {",
             "Task {\n        while Date().timeIntervalSince(triggered) < uploadDeadline {"),
            ("result before the wait", #"timer.mark("trigger_sent")"#,
             #"timer.mark("trigger_sent")"# + "\n            return .created(\"early\", pending: false)"),
            ("bare exit before the read repair", #"timer.mark("uploaded")"#, #"timer.mark("uploaded")"# + "\n                    break"),
            ("early return after the unread gate", "guard first == .stillUnread else { return first }",
             "guard first == .stillUnread else { return first }\n        return first"),
            ("re-assert commented out", "_ = try? await controller.markDirectDraftRead(rowId: inserted.messageRowId)",
             "// _ = try? await controller.markDirectDraftRead(rowId: inserted.messageRowId)"),
            // Round 2
            ("inline guarded exit before the read repair", #"timer.mark("uploaded")"#,
             #"timer.mark("uploaded")"# + "\n if fastPath { return .created(Self.createdText(seconds: seconds, uploaded: true), pending: false) }"),
            ("exit inside the wait loop", "let state = writer.uploadState(inserted)",
             "if Date().timeIntervalSince(triggered) > 2 { break }\n let state = writer.uploadState(inserted)"),
            ("created before the upload is confirmed", "let state = writer.uploadState(inserted)",
             "let state = writer.uploadState(inserted)\n if state.remoteId == nil && skip { return .created(\"x\", pending: false) }"),
            ("wait clock shifted", "let triggered = Date()", "let triggered = Date().addingTimeInterval(-9)"),
            ("wait detached with a priority", "while Date().timeIntervalSince(triggered) < uploadDeadline {",
             "Task(priority: .utility) {\n while Date().timeIntervalSince(triggered) < uploadDeadline {"),
            ("early return at the top of ensureRead", "var looks: [Bool?] = []",
             "if skip { return .confirmed }\n var looks: [Bool?] = []"),
            ("fewer probes before the gate", "for attempt in 0..<4 {", "for attempt in 0..<1 {"),
            ("fewer probes after the re-assert", "for _ in 0..<8 {", "for _ in 0..<1 {"),
            // Round 3
            ("local closure shadowing ensureRead", #"timer.mark("inserted")"#,
             "let ensureRead: (DraftStoreWriter, DraftStoreWriter.Inserted) async -> ReadOutcome = { _, _ in .confirmed }\n        "
             + #"timer.mark("inserted")"#),
            ("section wrapped, created returned after it",
             "uploadDeadline, uploaded: false), pending: true)\n    }\n",
             "uploadDeadline, uploaded: false), pending: true)\n        }\n        return .created(\"fast\", pending: false)\n    }\n"),
            ("call switched to a copy", "let outcome = await attemptSteps(", "let outcome = await attemptStepsFast("),
        ]
        XCTAssertEqual(Self.itemSevenViolations(in: source), [], "the real source must pass before edits are meaningful")
        for edit in edits {
            XCTAssertEqual(source.components(separatedBy: edit.find).count, 2,
                           "`\(edit.find)` must occur exactly once for the edit '\(edit.name)' to mean anything")
            let edited = source.replacingOccurrences(of: edit.find, with: edit.replace)
            XCTAssertFalse(Self.itemSevenViolations(in: edited).isEmpty, "not caught: \(edit.name)")
        }
    }

    // MARK: - Item 7: the wait limit

    func testUploadWaitIsNotShortened() {
        XCTAssertGreaterThanOrEqual(
            DirectDraftPath(controller: MailController.shared, reader: nil).uploadDeadline, 10,
            "rule item 7: the upload wait is what finds a draft that did not upload and what lets the read repair "
            + "run. A shorter wait is a speed change: bring the trigger and upload-confirm time distributions first.")
    }

    /// The only lines in `Sources` that may name `uploadDeadline`. Any other
    /// use, such as overriding it where the path is built, changes the wait
    /// without touching the default the test above reads (Round 1).
    static let allowedUploadDeadlineLines = [
        "DirectDraftPath.swift|var uploadDeadline: TimeInterval = 10",
        "DirectDraftPath.swift|while Date().timeIntervalSince(triggered) < uploadDeadline {",
        "DirectDraftPath.swift|return .created(Self.createdText(seconds: uploadDeadline, uploaded: false), pending: true)",
    ]

    static func uses(of name: String, in files: [(name: String, source: String)]) -> [String] {
        files.flatMap { file in
            codeLines(of: file.source).filter { $0.contains(name) }.map { "\(file.name)|\($0)" }
        }.sorted()
    }

    private static func sourceFiles() throws -> [(name: String, source: String)] {
        let sources = repoRoot.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var files: [(name: String, source: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    func testUploadDeadlineIsOnlySetByItsDefault() throws {
        let files = try Self.sourceFiles()
        XCTAssertGreaterThan(files.count, 20, "the Sources scan read too few files to mean anything")
        XCTAssertEqual(Self.uses(of: "uploadDeadline", in: files), Self.allowedUploadDeadlineLines.sorted(),
                       "rule item 7: uploadDeadline is used somewhere other than its default, the wait loop and the "
                       + "pending result" + Self.hint)
        let overridden = files + [("Server.swift", "let path = DirectDraftPath(controller: c, reader: r, uploadDeadline: 2)")]
        XCTAssertNotEqual(Self.uses(of: "uploadDeadline", in: overridden), Self.allowedUploadDeadlineLines.sorted(),
                          "an override at the call site must be caught")
    }

    /// The names pinned by `pinnedNameLines` appear nowhere else in `Sources`
    /// either, so no other file declares or calls them (round 3).
    func testFrozenSectionNamesAreUsedOnlyWherePinned() throws {
        let files = try Self.sourceFiles()
        for pinned in Self.pinnedNameLines {
            XCTAssertEqual(Self.uses(of: pinned.name, in: files), pinned.lines.map { "DirectDraftPath.swift|\($0)" }.sorted(),
                           "rule item 7: `\(pinned.name)` is used outside its declaration and its one call" + Self.hint)
        }
    }

    // MARK: - Comment stripping

    func testCommentStrippersKeepCodeAndDropComments() {
        XCTAssertEqual(Self.strippingSwiftComments("a // b"), "a ")
        XCTAssertEqual(Self.strippingSwiftComments(#"x.hasPrefix("imap://") else {"#), #"x.hasPrefix("imap://") else {"#)
        XCTAssertEqual(Self.strippingSwiftComments(#"f("a\"//b") // c"#), #"f("a\"//b") "#)
        XCTAssertEqual(Self.strippingSwiftComments("/* x\n y */z"), "\nz", "line breaks inside a block comment are kept")
        XCTAssertEqual(Self.strippingSwiftComments("a /* b /* c */ d */ e"), "a  e", "Swift block comments nest")
        // Round 2: a `/*` inside a line comment (MIMEParser.swift has `multipart/*`
        // in doc comments) must not open a block that swallows later code.
        XCTAssertEqual(Self.strippingSwiftComments("/// multipart/*\nlet a = 1\nlet b = \"*/\""),
                       "\nlet a = 1\nlet b = \"*/\"")
        XCTAssertEqual(Self.strippingSwiftComments(##"#"a // b"# // c"##), ##"#"a // b"# "##)
        XCTAssertEqual(Self.strippingSwiftComments("\"\"\"\nx // y\n\"\"\""), "\"\"\"\nx // y\n\"\"\"",
                       "a multi-line string literal is not code")
        XCTAssertEqual(Self.strippingSwiftComments("#filePath // c"), "#filePath ")
        XCTAssertEqual(Self.strippingAppleScriptComments("delay 0.5 -- c"), "delay 0.5 ")
        XCTAssertEqual(Self.strippingAppleScriptComments(#"log "a -- b # c""#), #"log "a -- b # c""#)
        XCTAssertEqual(Self.strippingAppleScriptComments("(* a\n b *)delay 1"), "\ndelay 1")
        XCTAssertEqual(Self.strippingAppleScriptComments("(* a (* b *) c *)delay 1"), "delay 1")
        XCTAssertEqual(Self.strippingAppleScriptComments("# c\ndelay 1"), "\ndelay 1")
        XCTAssertEqual(Self.strippingAppleScriptComments("log \"a\n-- b\" -- c"), "log \"a\n-- b\" ",
                       "an AppleScript string may span lines")
        XCTAssertEqual(Self.strippingAppleScriptComments("log \"ab\nc\" -- d", blankingStrings: true), "log \"  \n \" ")
    }

    // MARK: - Helpers

    /// Code lines of a Swift source: comments removed, whitespace trimmed,
    /// blank lines dropped.
    static func codeLines(of source: String) -> [String] {
        strippingSwiftComments(source).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Removes `//` line comments and nested `/* … */` blocks, leaving string
    /// literals (`"…"`, `"""…"""`, raw `#"…"#`) untouched. An interpolation
    /// containing its own string literal can end the outer literal early in
    /// this scan; the sources these tests read have none that matter.
    static func strippingSwiftComments(_ source: String) -> String {
        strippingComments(source, lineOpeners: ["//"], blockOpen: "/*", blockClose: "*/", swiftStrings: true)
    }

    /// Removes `--` and `#` line comments and nested `(* … *)` blocks. `"…"`
    /// strings, which may span lines in AppleScript, are kept, or with
    /// `blankingStrings` have their contents replaced by spaces (line breaks
    /// kept) so text inside a string is never read as a statement.
    static func strippingAppleScriptComments(_ script: String, blankingStrings: Bool = false) -> String {
        strippingComments(script, lineOpeners: ["--", "#"], blockOpen: "(*", blockClose: "*)", swiftStrings: false,
                          blankStrings: blankingStrings)
    }

    /// One pass over `text`: string literals are copied as they are (or
    /// blanked), comments are dropped, and the line breaks inside a block
    /// comment are kept so the line structure survives.
    private static func strippingComments(_ text: String, lineOpeners: [String], blockOpen: String,
                                          blockClose: String, swiftStrings: Bool,
                                          blankStrings: Bool = false) -> String {
        func body(_ ch: Character) -> Character { blankStrings && ch != "\n" ? " " : ch }
        let c = Array(text)
        var out: [Character] = []
        var i = 0
        func starts(_ token: String, at k: Int) -> Bool {
            let t = Array(token)
            return k + t.count <= c.count && Array(c[k..<(k + t.count)]) == t
        }
        while i < c.count {
            if lineOpeners.contains(where: { starts($0, at: i) }) {
                while i < c.count && c[i] != "\n" { i += 1 }
                continue
            }
            if starts(blockOpen, at: i) {
                var depth = 0
                while i < c.count {
                    if starts(blockOpen, at: i) { depth += 1; i += blockOpen.count; continue }
                    if starts(blockClose, at: i) {
                        depth -= 1
                        i += blockClose.count
                        if depth == 0 { break }
                        continue
                    }
                    if c[i] == "\n" { out.append("\n") }
                    i += 1
                }
                continue
            }
            var hashes = 0
            if swiftStrings { while i + hashes < c.count && c[i + hashes] == "#" { hashes += 1 } }
            if i + hashes < c.count && c[i + hashes] == "\"" {
                let quoteAt = i + hashes
                let multiLine = swiftStrings && starts("\"\"\"", at: quoteAt)
                let quote = multiLine ? "\"\"\"" : "\""
                let close = Array(quote + String(repeating: "#", count: hashes))
                let escape = "\\" + String(repeating: "#", count: hashes)
                let bodyStart = quoteAt + quote.count
                out.append(contentsOf: c[i..<bodyStart])
                i = bodyStart
                // Swift single-line literals end at a line break; AppleScript
                // strings may span lines (round 3).
                let spansLines = multiLine || !swiftStrings
                while i < c.count {
                    if starts(escape, at: i) && i + escape.count < c.count {
                        out.append(contentsOf: c[i...(i + escape.count)].map(body))
                        i += escape.count + 1
                        continue
                    }
                    if starts(String(close), at: i) {
                        out.append(contentsOf: close)
                        i += close.count
                        break
                    }
                    if !spansLines && c[i] == "\n" { break }
                    out.append(body(c[i]))
                    i += 1
                }
                continue
            }
            if hashes > 0 {
                out.append(contentsOf: c[i..<(i + hashes)])
                i += hashes
                continue
            }
            out.append(c[i])
            i += 1
        }
        return String(out)
    }

    private static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var cursor = text.startIndex
        while let range = text.range(of: needle, range: cursor..<text.endIndex) {
            result.append(range)
            cursor = range.upperBound
        }
        return result
    }

    /// The first capture group of each match, or the whole match when the
    /// pattern has no group.
    private static func matches(of pattern: String, in text: String, caseInsensitive: Bool = false) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern,
                                             options: caseInsensitive ? [.anchorsMatchLines, .caseInsensitive] : [.anchorsMatchLines])
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            ns.substring(with: match.numberOfRanges > 1 ? match.range(at: 1) : match.range)
        }
    }
}
