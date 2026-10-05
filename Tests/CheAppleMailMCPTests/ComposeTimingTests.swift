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
            "R1,swift,enter,100.000,0,0,ok,0.2,default,true,gui-mailto",
            "R1,swift,spawn,100.100,100,100,ok,0.2,default,true,gui-mailto",
            "R1,script,window_found,100.500,500,400,ok,0.2,default,true,gui-mailto",
        ])
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

    // MARK: - #475 Timing CSV layout / Mismatched header is refused

    static let header475 =
        "run_id,source,step,t_ref,ms_since_start,ms_since_prev,outcome,window_delay,step_delay,from_address_set,path"
    static let header464 =
        "run_id,source,step,t_ref,ms_since_start,ms_since_prev,outcome,window_delay,step_delay,from_address_set"

    private func tempCSV() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-timing-\(UUID().uuidString).csv").path
    }

    func testHeaderEndsWithThePathColumn() {
        XCTAssertEqual(ComposeTiming.csvHeader, Self.header475)
    }

    func testNewFileStartsWithTheElevenColumnHeader() throws {
        let path = tempCSV()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let rows = ComposeTiming.csvRows(runId: "R1", marks: [
            ComposeTiming.Mark(source: "swift", label: "enter", time: 1.0)], outcome: "ok", config: [:])
        try ComposeTiming.append(rows: rows, toCSVAt: path)
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(String(lines[0]), Self.header475)
        for line in lines { XCTAssertEqual(line.split(separator: ",", omittingEmptySubsequences: false).count, 11) }
    }

    func testFileWithTheOldHeaderIsRefusedAndLeftUnchanged() throws {
        let path = tempCSV()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let original = Self.header464 + "\nR0,swift,enter,1.000,0,0,ok,,,true\n"
        try original.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ComposeTiming.append(rows: ["x"], toCSVAt: path)) { error in
            // The caller logs `error.localizedDescription`; it must name the file and the mismatch.
            XCTAssertTrue(error.localizedDescription.contains("header"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(path), error.localizedDescription)
        }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), original)
    }

    func testNoFieldContainsAComma() {
        let rows = ComposeTiming.csvRows(runId: "R1", marks: [
            ComposeTiming.Mark(source: "swift", label: "enter", time: 1.0)], outcome: "ok",
            config: ["window_delay": "0.2,0.3", "step_delay": "default", "from_address_set": "true"])
        XCTAssertEqual(rows, ["R1,swift,enter,1.000,0,0,ok,0.2;0.3,default,true,gui-mailto"])
    }

    // MARK: - #475 segments: one run across the direct and GUI paths

    func testSegmentsMergeIntoOneRunMeasuredFromTheEarliestMark() {
        let direct = ComposeTiming.Segment(
            path: "direct", outcome: "not_attempted:version",
            config: ["from_address_set": "true"],
            marks: [ComposeTiming.Mark(source: "swift", label: "returned", time: 10.040),
                    ComposeTiming.Mark(source: "swift", label: "enter", time: 10.000)])
        let gui = ComposeTiming.Segment(
            path: "gui-mailto", outcome: "ok",
            config: ["window_delay": "default", "step_delay": "default", "from_address_set": "true"],
            marks: [ComposeTiming.Mark(source: "swift", label: "enter", time: 10.050),
                    ComposeTiming.Mark(source: "swift", label: "returned", time: 16.300)])
        // Segments are passed GUI-first on purpose: order comes from time, not argument order.
        XCTAssertEqual(ComposeTiming.csvRows(runId: "R9", segments: [gui, direct]), [
            "R9,swift,enter,10.000,0,0,not_attempted:version,,,true,direct",
            "R9,swift,returned,10.040,40,40,not_attempted:version,,,true,direct",
            "R9,swift,enter,10.050,50,10,ok,default,default,true,gui-mailto",
            "R9,swift,returned,16.300,6300,6250,ok,default,default,true,gui-mailto",
        ])
    }

    func testNoSegmentsProduceNoRows() {
        XCTAssertEqual(ComposeTiming.csvRows(runId: "R0", segments: []), [])
        XCTAssertEqual(ComposeTiming.csvRows(runId: "R0", segments: [
            ComposeTiming.Segment(path: "direct", outcome: "created", config: [:], marks: [])]), [])
    }

    // MARK: - #475 run context

    private struct Boom: Error {}

    private func seg(_ path: String, _ label: String, _ t: TimeInterval) -> ComposeTiming.Segment {
        ComposeTiming.Segment(path: path, outcome: "ok", config: [:],
                              marks: [ComposeTiming.Mark(source: "swift", label: label, time: t)])
    }

    private func dataLines(_ path: String) throws -> [Substring] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").dropFirst().map { $0 }
    }

    func testSegmentsRecordedInsideARunShareOneRunIdAndAreWrittenAtTheEnd() async throws {
        let path = tempCSV()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await ComposeTiming.withRun(csvPath: path) {
            ComposeTiming.record(seg("direct", "enter", 1.0), csvPath: path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "nothing is written until the run ends")
            ComposeTiming.record(seg("gui-mailto", "returned", 2.0), csvPath: path)
        }
        let lines = try dataLines(path)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(Set(lines.map { $0.split(separator: ",")[0] }).count, 1, "one run_id for the whole call")
        XCTAssertTrue(lines[0].hasSuffix(",direct"))
        XCTAssertTrue(lines[1].hasSuffix(",gui-mailto"))
    }

    func testARunThatThrowsStillWritesItsRows() async throws {
        let path = tempCSV()
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            try await ComposeTiming.withRun(csvPath: path) {
                ComposeTiming.record(seg("direct", "enter", 1.0), csvPath: path)
                throw Boom()
            }
            XCTFail("the body's error must propagate")
        } catch is Boom {}
        XCTAssertEqual(try dataLines(path).count, 1)
    }

    func testRecordingOutsideARunWritesImmediately() throws {
        let path = tempCSV()
        defer { try? FileManager.default.removeItem(atPath: path) }
        ComposeTiming.record(seg("gui-mailto", "enter", 1.0), csvPath: path)
        XCTAssertEqual(try dataLines(path).count, 1)
    }

    func testNoRunAndNoFileWhenTimingIsOff() async throws {
        let ran = try await ComposeTiming.withRun(csvPath: nil) { () -> Bool in
            XCTAssertNil(ComposeTiming.currentRun, "no run context without the opt-in")
            return true
        }
        XCTAssertTrue(ran)
    }

    // MARK: - #475 GUI mailto path marks join the run

    func testGuiTimingInsideARunJoinsTheRunWithTheGuiMailtoPath() async throws {
        let path = tempCSV()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = ComposeTiming.takeCapturedMarks()
        try await ComposeTiming.withRun(csvPath: path) {
            MailController.shared.recordComposeTiming(enter: 1.0, spawn: 1.1, outcome: "ok",
                                                      fromAddressSet: true, csvPath: path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "inside a run the GUI path does not write")
            XCTAssertEqual(ComposeTiming.currentRun?.collected.first?.path, "gui-mailto")
        }
        let lines = try dataLines(path)
        XCTAssertEqual(lines.map { String($0.split(separator: ",")[2]) }, ["enter", "spawn", "returned"])
        XCTAssertTrue(lines.allSatisfy { $0.hasSuffix(",ok,default,default,true,gui-mailto") })
    }

    func testGuiTimingOutsideARunWritesItsOwnRows() throws {
        let path = tempCSV()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = ComposeTiming.takeCapturedMarks()
        MailController.shared.recordComposeTiming(enter: 1.0, spawn: 1.1, outcome: "error",
                                                  fromAddressSet: false, csvPath: path)
        let lines = try dataLines(path)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.allSatisfy { $0.hasSuffix(",error,default,default,false,gui-mailto") })
    }

    // MARK: - #475 verify R1 (Codex): quotes and concurrent writers

    func testNoFieldContainsADoubleQuote() {
        // A standard CSV reader treats `"` as a field delimiter; an env value such as
        // `"0.2` would swallow the rest of the row into one quoted field.
        let rows = ComposeTiming.csvRows(runId: "R1", marks: [
            ComposeTiming.Mark(source: "swift", label: "enter", time: 1.0)], outcome: "ok",
            config: ["window_delay": "\"0.2", "step_delay": "\"1\"", "from_address_set": "true"])
        XCTAssertEqual(rows, ["R1,swift,enter,1.000,0,0,ok,'0.2,'1',true,gui-mailto"])
    }

    func testConcurrentAppendsKeepEveryRowAndOneHeader() throws {
        let path = tempCSV()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writers = 16
        DispatchQueue.concurrentPerform(iterations: writers) { i in
            try? ComposeTiming.append(rows: ["row-\(i)-a", "row-\(i)-b"], toCSVAt: path)
        }
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.filter { $0 == Self.header475 }.count, 1, "the header is written exactly once")
        XCTAssertEqual(lines.first, Self.header475)
        let rows = Set(lines.dropFirst())
        for i in 0..<writers {
            XCTAssertTrue(rows.contains("row-\(i)-a") && rows.contains("row-\(i)-b"), "writer \(i) lost its rows")
        }
        XCTAssertEqual(lines.count, 1 + 2 * writers, "no row is duplicated or truncated")
    }

    func testCapturedMarksAreTakenOnce() {
        ComposeTiming.captureStderr("\(ComposeTiming.logPrefix)x|1.0\n")
        XCTAssertEqual(ComposeTiming.takeCapturedMarks().map(\.label), ["x"])
        XCTAssertEqual(ComposeTiming.takeCapturedMarks().count, 0, "taking clears the buffer")
    }
}
