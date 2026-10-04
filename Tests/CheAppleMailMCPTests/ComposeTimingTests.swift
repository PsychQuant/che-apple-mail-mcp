import XCTest
@testable import CheAppleMailMCP

/// #464 — opt-in per-step timing for the GUI compose path.
///
/// End-to-end numbers could not say which wait mattered: a sweep of the env
/// delays showed the window wait could drop from 1.8 s to 0.2 s with the draft
/// still correct, while a step delay of 0 failed the sender read-back. Timing
/// each step answers that directly. Enabled only by `CHE_MAIL_COMPOSE_TIMING_CSV`;
/// with it unset the generated script must not change at all.
final class ComposeTimingTests: XCTestCase {

    private func script(timing: Bool, from: String? = "me@corp.example") -> String {
        buildMailtoComposeScript(
            url: "mailto:a@x?subject=S", subject: "S", attachments: [],
            send: false, fromAddress: from, timing: timing)
    }

    func testDisabledTimingLeavesTheScriptUntouched() {
        let off = script(timing: false)
        XCTAssertFalse(off.contains("_cheMailMark"), "no mark calls without the opt-in")
        XCTAssertFalse(off.contains("use framework"), "no ASObjC prelude without the opt-in")
        XCTAssertFalse(off.contains(ComposeTiming.logPrefix))
    }

    func testDefaultFollowsTheEnvironment() {
        // The test process does not set CHE_MAIL_COMPOSE_TIMING_CSV.
        XCTAssertNil(ProcessInfo.processInfo.environment[ComposeTiming.envKey])
        XCTAssertEqual(
            buildMailtoComposeScript(url: "mailto:a@x?subject=S", subject: "S", attachments: [], send: false),
            script(timing: false, from: nil),
            "the default must equal timing:false when the env var is unset")
    }

    func testEnabledTimingPutsThePreludeFirst() {
        let on = script(timing: true)
        XCTAssertTrue(on.hasPrefix("use framework \"Foundation\"\nuse scripting additions\n"),
            "`use` clauses must be the first statements of the script")
        XCTAssertTrue(on.contains("on _cheMailMark(_label)"))
        XCTAssertTrue(on.contains("log \"\(ComposeTiming.logPrefix)\""),
            "marks go to stderr through AppleScript's log, so the transport needs no new channel")
    }

    func testEnabledTimingMarksEveryStepInOrder() {
        let on = script(timing: true)
        let steps = ["script_start", "mailto_sent", "window_found", "raised",
                     "popup_found", "popup_clicked", "menu_ready", "sender_verified",
                     "sender_settled", "pre_dispatch", "dispatched", "script_end"]
        var last = on.startIndex
        for step in steps {
            guard let r = on.range(of: "my _cheMailMark(\"\(step)\")", range: last..<on.endIndex) else {
                return XCTFail("missing or out of order: \(step)")
            }
            last = r.upperBound
        }
    }

    func testNoSenderStepsWithoutFromAddress() {
        let on = script(timing: true, from: nil)
        XCTAssertFalse(on.contains("my _cheMailMark(\"popup_found\")"))
        XCTAssertTrue(on.contains("my _cheMailMark(\"pre_dispatch\")"))
    }

    func testParseMarksIgnoresNoiseAndMalformedLines() {
        let stderr = """
        some log noise
        \(ComposeTiming.logPrefix)window_found|7.81234567891234E+8
        \(ComposeTiming.logPrefix)broken
        \(ComposeTiming.logPrefix)dispatched|781234570.25
        \(ComposeTiming.logPrefix)comma_locale|781234571,5
        0:10: execution error: something (-1)
        """
        let marks = ComposeTiming.parseMarks(fromStderr: stderr)
        XCTAssertEqual(marks.map(\.label), ["window_found", "dispatched", "comma_locale"])
        XCTAssertEqual(marks[0].time, 781234567.891234, accuracy: 1e-6)
        XCTAssertEqual(marks[1].time, 781234570.25, accuracy: 1e-9)
        XCTAssertEqual(marks[2].time, 781234571.5, accuracy: 1e-9, "a comma decimal separator is accepted")
        XCTAssertTrue(marks.allSatisfy { $0.source == "script" })
    }

    func testCSVRowsAreSortedWithMillisecondOffsetsAndDeltas() {
        let marks = [
            ComposeTiming.Mark(source: "script", label: "window_found", time: 100.500),
            ComposeTiming.Mark(source: "swift", label: "enter", time: 100.000),
            ComposeTiming.Mark(source: "swift", label: "spawn", time: 100.100),
        ]
        let rows = ComposeTiming.csvRows(runId: "R1", marks: marks, outcome: "ok",
                                         config: ["window_delay": "0.2", "step_delay": "default", "from_address_set": "true"])
        XCTAssertEqual(rows, [
            "R1,swift,enter,100.000,0,0,ok,0.2,default,true",
            "R1,swift,spawn,100.100,100,100,ok,0.2,default,true",
            "R1,script,window_found,100.500,500,400,ok,0.2,default,true",
        ])
        XCTAssertEqual(ComposeTiming.csvHeader,
            "run_id,source,step,t_ref,ms_since_start,ms_since_prev,outcome,window_delay,step_delay,from_address_set")
    }

    func testAppendWritesTheHeaderOnlyOnce() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-timing-\(UUID().uuidString).csv").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try ComposeTiming.append(rows: ["a"], toCSVAt: path)
        try ComposeTiming.append(rows: ["b", "c"], toCSVAt: path)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8),
                       ComposeTiming.csvHeader + "\na\nb\nc\n")
    }

    func testCapturedMarksAreTakenOnce() {
        ComposeTiming.captureStderr("\(ComposeTiming.logPrefix)x|1.0\n")
        XCTAssertEqual(ComposeTiming.takeCapturedMarks().map(\.label), ["x"])
        XCTAssertEqual(ComposeTiming.takeCapturedMarks().count, 0, "taking clears the buffer")
    }
}
