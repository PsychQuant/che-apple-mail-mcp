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
        }
        let marks = run.collected.first?.marks ?? []
        XCTAssertTrue(marks.contains { $0.label == "trigger_listed" && $0.source == "script" })
        XCTAssertFalse(marks.contains { $0.label == "script_start" })
        XCTAssertEqual(ComposeTiming.takeCapturedMarks().map(\.label), ["script_start"], "other marks stay for their owner")
    }

    func testTimerWithoutARunTakesNothing() {
        let timer = DirectDraftTimer(fromAddressSet: true)
        XCTAssertFalse(timer.isRecording)
        ComposeTiming.captureStderr("\(ComposeTiming.logPrefix)trigger_listed|1.0\n")
        timer.absorbScriptMarks()
        XCTAssertEqual(ComposeTiming.takeCapturedMarks().map(\.label), ["trigger_listed"])
    }
}
