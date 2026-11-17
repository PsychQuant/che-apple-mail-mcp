import XCTest
@testable import CheAppleMailMCP

/// #489 — the upload trigger split into timed sub-steps (compose-timing
/// requirement "Direct-write path marks").
final class DirectDraftTriggerTimingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = ComposeTiming.takeCapturedMarks()
    }

    override func tearDown() async throws {
        _ = ComposeTiming.takeCapturedMarks()
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
        try await super.tearDown()
    }

    // MARK: - Task 3.1: the trigger sends the builder's script for its timing flag

    func testTriggerSendsTheBuildersScriptForItsTimingFlag() async throws {
        final class Box: @unchecked Sendable { var sent: [String] = [] }
        let box = Box()
        await MailController.shared.setTestSeams(scriptRunner: { source in box.sent.append(source); return "toggled" },
                                                 refusal: nil)
        _ = try await MailController.shared.triggerDirectDraftUpload(rowId: 305619, timing: true)
        _ = try await MailController.shared.triggerDirectDraftUpload(rowId: 305619, timing: false)
        XCTAssertEqual(box.sent, [buildDirectDraftTriggerScript(rowId: 305619, timing: true),
                                  buildDirectDraftTriggerScript(rowId: 305619, timing: false)])
    }

    // MARK: - Task 1.1: the trigger script

    /// The trigger script as it was before #489, character for character.
    private static let untimedTrigger = """
        tell application "Mail"
            set _m to missing value
            repeat 40 times
                try
                    set _m to (first message of drafts mailbox whose id is 305619)
                    exit repeat
                end try
                delay 0.25
            end repeat
            if _m is missing value then error "DIRECTDRAFT: Mail did not list the new draft within 10 s"
            set read status of _m to false
            delay 0.5
            set read status of _m to true
            return "toggled"
        end tell
        """

    func testUntimedTriggerScriptIsUnchanged() {
        XCTAssertEqual(buildDirectDraftTriggerScript(rowId: 305619, timing: false), Self.untimedTrigger)
        XCTAssertFalse(buildDirectDraftTriggerScript(rowId: 305619, timing: false).contains(ComposeTiming.logPrefix))
    }

    func testTimedTriggerScriptMarksEachSubStepInOrder() throws {
        let script = buildDirectDraftTriggerScript(rowId: 305619, timing: true)
        XCTAssertTrue(script.hasPrefix(ComposeTiming.prelude), "use clauses must come first")
        let order = [
            ComposeTiming.markStatement("trigger_script_start"),
            "if _m is missing value then error",
            ComposeTiming.markStatement("trigger_listed"),
            "set read status of _m to false",
            ComposeTiming.markStatement("trigger_unread"),
            "delay 0.5",
            "set read status of _m to true",
            ComposeTiming.markStatement("trigger_read"),
            "return \"toggled\"",
        ]
        var cursor = script.startIndex
        for piece in order {
            let range = try XCTUnwrap(script.range(of: piece, range: cursor..<script.endIndex), "missing or out of order: \(piece)")
            cursor = range.upperBound
        }
    }

    func testTimedTriggerAddsOnlyTheUnreadMarkBetweenTheToggles() throws {
        let script = buildDirectDraftTriggerScript(rowId: 305619, timing: true)
        let off = try XCTUnwrap(script.range(of: "set read status of _m to false"))
        let on = try XCTUnwrap(script.range(of: "set read status of _m to true"))
        let between = script[off.upperBound..<on.lowerBound]
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        XCTAssertEqual(between, [ComposeTiming.markStatement("trigger_unread"), "delay 0.5"])
    }

    /// #492, evasions 4 and 5 on the timed path: without the prelude and the marks, what is left is the
    /// script pinned above, so a toggle or a branch cannot be added only when timing is on.
    func testTimedTriggerIsTheUntimedOnePlusItsMarks() {
        let timed = buildDirectDraftTriggerScript(rowId: 305619, timing: true)
        let marks = Set(["trigger_script_start", "trigger_listed", "trigger_unread", "trigger_read"]
            .map(ComposeTiming.markStatement))
        let rest = timed.dropFirst(ComposeTiming.prelude.count).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !marks.contains($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(rest.joined(separator: "\n"), Self.untimedTrigger)
    }

    // MARK: - #650: the timed path's two remaining free-text pieces

    /// #650, evasions 4 and 5 on the timed path. Test 3 above removes the prelude by its length and the
    /// mark lines by whatever `markStatement` returns, so on its own neither is compared with fixed text,
    /// and a statement placed in the `_cheMailMark` handler body (a toggle phrased as `set the read status
    /// of`, a branch, a `delay`) would run between the two toggles whenever timing is on while its text sits
    /// above them. The prelude is pinned here, and the whole timed script by the golden below. The prelude is
    /// shared with the compose path's timing: a deliberate change to that has to update this copy too.
    func testTimingPreludeIsPinnedCharacterForCharacter() {
        let golden = """
            use framework "Foundation"
            use scripting additions
            on _cheMailMark(_label)
                log "CHE_MAIL_TIMING|" & _label & "|" & ((current application's NSDate's timeIntervalSinceReferenceDate()) as text)
            end _cheMailMark

            """
        XCTAssertEqual(ComposeTiming.prelude, golden,
                       "ComposeTiming.prelude is shared with the compose path's timing; the timed direct-write trigger runs it between the two read-status toggles, so a change here is a change to that script (#650, rule item 8)")
        XCTAssertEqual(ComposeTiming.logPrefix, "CHE_MAIL_TIMING|")
    }

    /// #650: `markStatement`'s output is filtered out of the timed script by test 3 whatever it is, so text
    /// appended to it would be invisible there. Every label the trigger uses is checked with a hard-coded
    /// expectation (not computed with `markStatement`), so output that depends on the label cannot pass.
    func testMarkStatementIsOneCallToTheHandlerAndNothingElse() {
        for label in ["trigger_script_start", "trigger_listed", "trigger_unread", "trigger_read", "x"] {
            XCTAssertEqual(ComposeTiming.markStatement(label), "my _cheMailMark(\"\(label)\")")
        }
    }

    /// #650, review round 1: the whole timed trigger script, written out. Test 3 filters the mark lines by
    /// set membership and trims them, and `dropFirst(prelude.count)` never looks at the dropped text, so
    /// neither the number nor the place nor the indentation of the four marks was pinned. This copy fixes all
    /// of it for the timed path, independently of `ComposeTiming`. The only thing outside it is the row id,
    /// an integer.
    func testTimedTriggerScriptIsPinnedWholeWithFourMarksInPlace() {
        let golden = """
            use framework "Foundation"
            use scripting additions
            on _cheMailMark(_label)
                log "CHE_MAIL_TIMING|" & _label & "|" & ((current application's NSDate's timeIntervalSinceReferenceDate()) as text)
            end _cheMailMark
            tell application "Mail"
                    my _cheMailMark("trigger_script_start")
                set _m to missing value
                repeat 40 times
                    try
                        set _m to (first message of drafts mailbox whose id is 305619)
                        exit repeat
                    end try
                    delay 0.25
                end repeat
                if _m is missing value then error "DIRECTDRAFT: Mail did not list the new draft within 10 s"
                    my _cheMailMark("trigger_listed")
                set read status of _m to false
                    my _cheMailMark("trigger_unread")
                delay 0.5
                set read status of _m to true
                    my _cheMailMark("trigger_read")
                return "toggled"
            end tell
            """
        XCTAssertEqual(buildDirectDraftTriggerScript(rowId: 305619, timing: true), golden)
    }

    // MARK: - Task 2.1: taking only some captured marks

    func testTakingMatchingMarksLeavesTheOthersInTheBuffer() {
        ComposeTiming.captureStderr("\(ComposeTiming.logPrefix)trigger_x|1.0\n\(ComposeTiming.logPrefix)script_start|2.0\n")
        let taken = ComposeTiming.takeCapturedMarks(where: { $0.label.hasPrefix("trigger_") })
        XCTAssertEqual(taken.map(\.label), ["trigger_x"])
        XCTAssertEqual(ComposeTiming.takeCapturedMarks().map(\.label), ["script_start"])
    }

    // MARK: - Task 2.2: the direct segment absorbs the trigger's marks

    func testTimerAbsorbsTriggerMarksIntoItsSegment() {
        let run = ComposeTiming.Run()
        ComposeTiming.$currentRun.withValue(run) {
            let timer = DirectDraftTimer(fromAddressSet: true)
            XCTAssertTrue(timer.isRecording)
            ComposeTiming.captureStderr("\(ComposeTiming.logPrefix)trigger_listed|1.0\n\(ComposeTiming.logPrefix)script_start|2.0\n")
            timer.absorbScriptMarks()
            timer.finish(.fellBack("r"))
            XCTAssertEqual(ComposeTiming.takeCapturedMarks().map(\.label), ["script_start"], "other marks stay for their owner")
        }
        let marks = run.collected.first?.marks ?? []
        XCTAssertTrue(marks.contains { $0.label == "trigger_listed" && $0.source == "script" })
        XCTAssertFalse(marks.contains { $0.label == "script_start" })
    }

    func testTimerWithoutARunTakesNothing() {
        let timer = DirectDraftTimer(fromAddressSet: true)
        XCTAssertFalse(timer.isRecording)
        ComposeTiming.captureStderr("\(ComposeTiming.logPrefix)trigger_listed|1.0\n")
        timer.absorbScriptMarks()
        XCTAssertEqual(ComposeTiming.takeCapturedMarks().map(\.label), ["trigger_listed"])
    }
}
