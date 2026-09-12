import XCTest
@testable import CheAppleMailMCP

/// #333 / #404 — `close <mailto window> saving no` does NOT close a mailto
/// compose window: Mail answers with the "save this message as a draft?" sheet
/// (AXIdentifier `Mail.sendMessageAlert`) and the window stays behind it — the
/// orphan-window chain #333 describes. The on-error cleanup must dismiss that
/// sheet through its discard button and confirm the window is gone; if the
/// window survives, the failure message says so and names the title.
final class ComposeCleanupSheetTests: XCTestCase {

    private func draftScript() -> String {
        buildMailtoComposeScript(url: "mailto:a@x?subject=S", subject: "S", attachments: [], send: false)
    }

    private enum BoundaryViolation: Error { case malformed(String), unsafe }

    /// Structural check for the line-oriented try syntax emitted by this
    /// builder, not a general AppleScript parser. Ignore -- inside strings.
    private func codeLine(_ raw: String) -> String {
        let chars = Array(raw)
        var quoted = false, escaped = false
        var end = chars.count
        for i in chars.indices {
            let c = chars[i]
            if quoted {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { quoted = false }
            } else if c == "\"" { quoted = true }
            else if c == "-", i + 1 < chars.count, chars[i + 1] == "-" { end = i; break }
        }
        return String(chars[..<end]).trimmingCharacters(in: .whitespaces)
    }

    private func cleanupBoundary(_ script: String) throws -> (start: Int, guards: [Int], lines: [String], refusalDepths: [Int]) {
        let lines = script.components(separatedBy: "\n").map(codeLine)
        var stack: [Int] = []
        var handlers: [Int] = []
        var depths: [Int] = []
        for (i, line) in lines.enumerated() {
            depths.append(stack.count)
            if line == "try" { stack.append(i) }
            else if line == "end try" {
                guard !stack.isEmpty else { throw BoundaryViolation.malformed("unmatched end try") }
                stack.removeLast()
            } else if line == "on error _mErr" || line.hasPrefix("on error _mErr ") {
                guard let start = stack.last else { throw BoundaryViolation.malformed("handler without try") }
                handlers.append(start)
            }
        }
        guard stack.isEmpty, handlers.count == 1 else {
            throw BoundaryViolation.malformed("expected one balanced compose error handler")
        }
        let prefixes = ["if _beforeTitles contains ", "if _ourMatches is 0 then error ",
                        "if _ourMatches > 1 then error "]
        var guards: [Int] = []
        for prefix in prefixes {
            let matches = lines.indices.filter { lines[$0].hasPrefix(prefix) && lines[$0].contains(" then error ") }
            guard matches.count == 1 else { throw BoundaryViolation.malformed("missing or duplicate ownership refusal") }
            guards.append(matches[0])
        }
        let captured = lines.indices.filter { lines[$0] == "set _ourId to (id of _cw)" }
        guard captured.count == 1 else { throw BoundaryViolation.malformed("missing or duplicate owned-id capture") }
        return (handlers[0], guards + captured, lines, guards.map { depths[$0] })
    }

    private func verifyCleanupBoundary(_ script: String) throws {
        let boundary = try cleanupBoundary(script)
        guard boundary.guards.allSatisfy({ $0 < boundary.start }),
              boundary.refusalDepths.allSatisfy({ $0 == 0 }) else { throw BoundaryViolation.unsafe }
    }

    func testCleanupTryBeginsAfterOwnershipForAllGeneratedVariants() throws {
        let fills: [[RecipientFill]] = [[], [.init(field: .cc, recipients: ["Named <n@example.test>"])],
                                       [.init(field: .bcc, recipients: ["Named <n@example.test>"])]]
        let senders: [String?] = [nil, "sender@example.test"]
        for send in [false, true] {
            for fill in fills {
                for sender in senders {
                    // The comment-shaped subject must not confuse codeLine.
                    let script = buildMailtoComposeScript(url: "mailto:a@example.test?subject=S",
                        subject: "S -- \"quoted\"", attachments: [], send: send, fromAddress: sender, fill: fill)
                    XCTAssertNoThrow(try verifyCleanupBoundary(script), "send=\(send) fill=\(fill) sender=\(String(describing: sender))")
                }
            }
        }
    }

    func testBoundaryCheckRejectsEarlyTryMovedOrSwallowedGuards() throws {
        for send in [false, true] {
            let script = buildMailtoComposeScript(url: "mailto:a@example.test?subject=S", subject: "S",
                                                 attachments: [], send: send)
            let boundary = try cleanupBoundary(script)
            let original = script.components(separatedBy: "\n")
            let identificationTell = try XCTUnwrap(boundary.lines.indices.last {
                $0 < boundary.guards[0] && boundary.lines[$0] == "tell application \"Mail\""
            })
            var earlyTry = original
            let tryLine = earlyTry.remove(at: boundary.start)
            earlyTry.insert(tryLine, at: identificationTell)
            var mutants = [earlyTry.joined(separator: "\n")]
            for guardIndex in boundary.guards.prefix(3) {
                var movedGuard = original
                let line = movedGuard.remove(at: guardIndex)
                // Removing a preceding guard shifts try back one line; inserting
                // at the original try index places the guard just inside it.
                movedGuard.insert(line, at: boundary.start)
                mutants.append(movedGuard.joined(separator: "\n"))
                // A separate try could swallow the refusal while leaving it
                // textually before the cleanup try; that is unsafe too.
                var swallowed = original
                swallowed.insert("end try", at: guardIndex + 1)
                swallowed.insert("try", at: guardIndex)
                mutants.append(swallowed.joined(separator: "\n"))
            }
            for mutant in mutants {
                XCTAssertThrowsError(try verifyCleanupBoundary(mutant)) { error in
                    guard case BoundaryViolation.unsafe = error else {
                        return XCTFail("mutation must fail ownership ordering, not token parsing: \(error)")
                    }
                }
            }
        }
    }

    func testRepeatedExistingTitleRefusalNeverLaunches() throws {
        let lines = draftScript().components(separatedBy: "\n")
        let begin = try XCTUnwrap(lines.firstIndex { codeLine($0) == "tell application \"Mail\"" })
        let end = try XCTUnwrap(lines.indices.first { $0 > begin && codeLine(lines[$0]) == "end tell" })
        let fragment = lines[(begin + 1)..<end].map { line -> String in
            let code = codeLine(line)
            if code == "activate" { return "set _activated to true" }
            if code.hasPrefix("mailto ") { return "set _launchCount to _launchCount + 1" }
            return line.replacingOccurrences(of: "id of every window", with: "{1}")
                .replacingOccurrences(of: "name of every window", with: "{\"S\"}")
        }.joined(separator: "\n")
        guard !fragment.contains("tell application") else { throw BoundaryViolation.malformed("unexpected application call") }
        let source = "set _launchCount to 0\nrepeat 3 times\ntry\n" + fragment
            + "\non error _ignored\nend try\nend repeat\nreturn _launchCount"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertEqual(text, "0", "repeated collision refusals must issue no compose launches")
    }

    func testExistingTitleIsRejectedBeforeLaunchingAnotherWindow() throws {
        for send in [false, true] {
            let script = buildMailtoComposeScript(url: "mailto:a@example.test?subject=S", subject: "S", attachments: [], send: send)
            let boundary = try cleanupBoundary(script)
            let launch = try XCTUnwrap(boundary.lines.firstIndex { $0.hasPrefix("mailto ") })
            XCTAssertLessThan(boundary.guards[0], launch, "same-title retries must refuse before opening another window")
        }
    }

    /// Run the actual post-launch identification control flow, replacing only
    /// window-property access with fixed lists. Never execute a Mail tell block.
    private func identifyFixture(_ windows: String) throws -> (Int32, String) {
        let lines = draftScript().components(separatedBy: "\n")
        let launch = try XCTUnwrap(lines.firstIndex { codeLine($0).hasPrefix("mailto ") })
        let begin = try XCTUnwrap(lines.indices.first { $0 > launch && codeLine(lines[$0]) == "tell application \"Mail\"" })
        let end = try XCTUnwrap(lines.indices.first { $0 > begin && codeLine(lines[$0]) == "end tell" })
        let fragment = lines[(begin + 1)..<end].joined(separator: "\n")
            .replacingOccurrences(of: "count of windows", with: "count of _testWindows")
            .replacingOccurrences(of: "repeat with _cw in windows", with: "repeat with _cw in _testWindows")
            .replacingOccurrences(of: "id of _cw", with: "item 1 of _cw")
            .replacingOccurrences(of: "name of _cw", with: "item 2 of _cw")
        guard !fragment.contains("tell application") else {
            throw BoundaryViolation.malformed("unexpected application call in fixture fragment")
        }
        let source = "set _wc to 1\nset _beforeIds to {1}\nset _beforeTitles to {\"Other\"}\nset _testWindows to "
            + windows + "\n" + fragment + "\nreturn _ourId as text"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
    }

    func testIdentificationDoesNotRequireNetWindowCountGrowth() throws {
        let (status, text) = try identifyFixture("{{2, \"S\"}}")
        XCTAssertEqual(status, 0, text)
        XCTAssertEqual(text, "2", "another window closing must not hide our new window")
    }

    func testIdentificationStillRejectsMissingOrAmbiguousOwnership() throws {
        let missing = try identifyFixture("{{1, \"Other\"}}")
        XCTAssertNotEqual(missing.0, 0)
        XCTAssertTrue(missing.1.contains("could not identify"), missing.1)
        let ambiguous = try identifyFixture("{{2, \"S\"}, {3, \"S\"}}")
        XCTAssertNotEqual(ambiguous.0, 0)
        XCTAssertTrue(ambiguous.1.contains("more than one new window"), ambiguous.1)
    }

    func testCleanupFailureHasItsOwnHandler() {
        for send in [false, true] {
            let s = buildMailtoComposeScript(url: "mailto:a@example.test?subject=S", subject: "S", attachments: [], send: send)
            XCTAssertTrue(s.contains("on error _cleanupErr"), "cleanup errors must not escape over the original sentinel")
            XCTAssertTrue(s.contains("CLEANUPFAILED:"), "the cleanup failure must be appended to the original error")
        }
    }

    /// Execute the production handler with a synthetic cleanup body. These
    /// scripts use only local variables/error statements, never Mail or AX.
    private func executeHandler(send: Bool, dispatched: Bool = false,
                                original: String = "FILLFIELD: original reason",
                                cleanup: String) throws -> String {
        let handler = buildComposeErrorHandler(cleanupBody: cleanup, send: send)
        let source = """
        set _dispatched to \(dispatched ? "true" : "false")
        set _cleanupRan to false
        try
            try
                error "\(appleScriptEscape(original))"
            on error _mErr
        \(handler)
            end try
        on error _observed
            return (_observed as text) & "||" & (_cleanupRan as text)
        end try
        error "handler swallowed the original error"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        XCTAssertEqual(process.terminationStatus, 0, text)
        return text
    }

    func testOriginalErrorSurvivesSuccessfulCleanup() throws {
        for send in [false, true] {
            let result = try executeHandler(send: send, cleanup: "set _cleanupRan to true")
            XCTAssertEqual(result, "FILLFIELD: original reason||true")
        }
    }

    func testCleanupFailureAppendsToOriginalError() throws {
        for send in [false, true] {
            let result = try executeHandler(send: send,
                cleanup: "set _cleanupRan to true\nerror \"cleanup denied\" number -1743")
            XCTAssertEqual(result, "FILLFIELD: original reason — CLEANUPFAILED: cleanup denied (compose window state unknown; inspect Mail before retrying)||true")
        }
    }

    func testPostDispatchErrorsNeverExecuteCleanup() throws {
        let cleanup = "set _cleanupRan to true\nerror \"cleanup must not run\""
        XCTAssertEqual(try executeHandler(send: true,
            original: "POSTDISPATCH: original reason", cleanup: cleanup),
            "POSTDISPATCH: original reason||false")
        XCTAssertEqual(try executeHandler(send: true, dispatched: true,
            original: "original tail failure", cleanup: cleanup),
            "POSTDISPATCH: original tail failure||false")
    }

    func testCleanup_dismissesDiscardSheet_byIdentifierAndExactDiscardTitle() {
        let s = draftScript()
        XCTAssertTrue(s.contains("close _cw saving no"), "the close attempt stays — it is the sheet it triggers that must be handled")
        XCTAssertTrue(s.contains("\"Mail.sendMessageAlert\""), "the sheet is recognized by its AXIdentifier")
        XCTAssertTrue(s.contains("\"不儲存\""), "zh-TW discard title")
        // R1 #11: `starts with "Don"` also matched "Done". Exact titles only,
        // both apostrophes macOS uses.
        XCTAssertTrue(s.contains("\"Don't Save\"") && s.contains("\"Don’t Save\""), s)
        XCTAssertFalse(s.contains("starts with \"Don"), "prefix match on the discard title is forbidden: \(s)")
    }

    func testCleanup_everyButtonClickIsGuardedByTheDiscardCondition() {
        // R1 #12: the old "never clicks save" assertion could not fail (the
        // generator always puts a newline between `then` and `click`). This
        // one reads the generated script line by line: every `click _b` must
        // sit directly under the exact discard-title condition.
        let lines = draftScript().components(separatedBy: "\n")
        var clicks = 0
        for (i, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "click _b" {
            clicks += 1
            let guardLine = lines[i - 1].trimmingCharacters(in: .whitespaces)
            XCTAssertEqual(guardLine, "if _bt is \"不儲存\" or _bt is \"Don't Save\" or _bt is \"Don’t Save\" then",
                           "click _b at line \(i + 1) is not guarded by the discard condition")
        }
        XCTAssertEqual(clicks, 1, "exactly one sheet-button click exists in cleanup")
    }

    func testCleanup_skipsTheSheetWhenTheTitleIsNotUnique() {
        // R1 #11: the sheet is found through the window TITLE (System Events
        // cannot see Mail's window ids). If more than one window carries our
        // subject, the discard click could hit someone else's unsaved message —
        // so cleanup must refuse to click and fall through to WINDOWLEFTOPEN.
        let s = draftScript()
        XCTAssertTrue(s.contains("_titleMatches"), s)
        XCTAssertTrue(s.contains("if _titleMatches is 1 then"), "the discard click must be gated on title uniqueness: \(s)")
    }

    func testCleanup_reportsSurvivingWindowByTitle() {
        let s = draftScript()
        XCTAssertTrue(s.contains("WINDOWLEFTOPEN:"), "a window that survives cleanup is reported, not silently left")
        XCTAssertTrue(s.contains("compose window titled \\\"S\\\" was left open"), s)
    }

    func testCleanup_distinguishesRefusedFromUndismissable() {
        // R2-10 (DA): when several windows carry the subject, cleanup
        // deliberately refuses to click — the message must say so, not claim
        // the sheet "could not be dismissed".
        let s = draftScript()
        XCTAssertTrue(s.contains("cleanup refused to dismiss its discard sheet because"), s)
        XCTAssertTrue(s.contains("windows carry this subject"), s)
        XCTAssertTrue(s.contains("its discard sheet could not be dismissed"), s)
    }

    func testCleanup_sendPath_keepsPostDispatchBranchUntouched() {
        // #242: after ⇧⌘D the window is the user's only evidence — the
        // POSTDISPATCH branch must not gain a sheet-dismissal that closes it.
        let s = buildMailtoComposeScript(url: "mailto:a@x?subject=S", subject: "S", attachments: [], send: true)
        let post = s.range(of: "if _mErr starts with \"POSTDISPATCH:\"")!.lowerBound
        let elseBranch = s.range(of: "else if _dispatched")!.lowerBound
        let between = s[post..<elseBranch]
        XCTAssertFalse(between.contains("sendMessageAlert"), "no cleanup inside the post-dispatch branch")
    }
}
