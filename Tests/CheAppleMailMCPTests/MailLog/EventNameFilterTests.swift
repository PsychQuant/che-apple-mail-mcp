import XCTest
import MCP
@testable import CheAppleMailMCP

/// #466 — the `events` parameter: keep only events whose DISPLAYED `event` name equals one of the
/// given values exactly. The displayed name is the one the output would carry, computed by the same
/// function, so a withheld template can be selected only as `<template withheld>` and never by its own
/// text (matching the raw template would reopen the oracle that keeps `contains` out of brief mode).
final class EventNameFilterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1790916206)
    private let window: [String: Value] = ["since": .string("2026-10-02T12:00:00+08:00"),
                                           "until": .string("2026-10-02T12:10:00+08:00")]
    private let template = "%@ Received %lu new local message actions"
    private let receiptMessage = "[Fixture.Server] <connection id:[Mailbox name=Fixture]> Read: 7 OK [APPENDUID (1695, 902)]"
    private let withheldFormat = "Sending to someone@example.invalid %@"

    private func call(_ args: [String: Value], source: FakeLogSource) async throws -> [String: Any] {
        let text = try await MailLogTool.handle(arguments: window.merging(args) { _, new in new }, source: source,
                                                now: now, timeZone: Synthetic.taipei)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func run(_ source: FakeLogSource, _ query: MailLogQuery) -> [String: Any] {
        MailLogService(source: source, timeZone: Synthetic.taipei).run(query)
    }

    private func query(_ events: [String]?, detail: MailLogDetail = .brief, contains: String? = nil,
                       limit: Int = 200, offset: Int = 0) -> MailLogQuery {
        MailLogQuery(detail: detail, start: Synthetic.base, end: Synthetic.base.addingTimeInterval(600), categories: [],
                     contains: contains, redactIdentifiers: false, limit: limit, offset: offset, events: events)
    }

    private func receipt(_ offset: Double, activity: Int = 0) -> Data {
        Synthetic.line(offset: offset, category: "IMAPConnection", format: "%{public}@", message: receiptMessage, activity: activity)
    }

    private func noise(_ offset: Double, activity: Int = 0) -> Data {
        Synthetic.line(offset: offset, category: "IMAPConnection", format: "%{public}@",
                       message: "[Fixture.Server] <connection id:[Mailbox name=Fixture]> Write: 8 NOOP", activity: activity)
    }

    // MARK: - spec-example: mail-log-diagnostics / event-name filter validation

    private func expectRejected(_ value: Value, _ why: String, file: StaticString = #filePath, line: UInt = #line) async {
        let source = FakeLogSource(lines: [Synthetic.line(offset: 0)])
        do {
            _ = try await call(["events": value], source: source)
            XCTFail("expected an invalid-parameter error: \(why)", file: file, line: line)
        } catch {
            XCTAssertTrue(source.requests.isEmpty, "the log reader must not be started: \(why)", file: file, line: line)
        }
    }

    private func expectAccepted(_ value: Value, echo: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        let r = try await call(["events": value], source: FakeLogSource(lines: [Synthetic.line(offset: 0)]))
        XCTAssertEqual(r["events"] as? [String], echo, file: file, line: line)
    }

    func testValidationTable() async throws {
        // spec-example: mail-log-diagnostics / event-name filter validation
        try await expectAccepted(.array([.string("imap.append_uid_received")]), echo: ["imap.append_uid_received"])
        try await expectAccepted(.array([.string(template)]), echo: [template])
        try await expectAccepted(.array([.string("<template withheld>")]), echo: ["<template withheld>"])
        await expectRejected(.array([.string("imap.append_uid_recieved")]), "unknown known-event name")
        await expectRejected(.array([]), "empty")
        await expectRejected(.array((0..<21).map { .string("e\($0)") }), "more than 20")
        await expectRejected(.array([.string("")]), "empty entry")
        await expectRejected(.array([.string(String(repeating: "é", count: 512) + "x")]), "1025 bytes")
        try await expectAccepted(.array([.string(String(repeating: "é", count: 512))]),
                                 echo: [String(repeating: "é", count: 512)])
        await expectRejected(.string("imap.append_uid_received"), "a string, not an array")
        await expectRejected(.array([.int(1)]), "non-string entry")
        try await expectAccepted(.array([.string("a"), .string("a"), .string("b")]), echo: ["a", "b"])
    }

    func testTwentyEntriesAreAccepted_andDetailedModeAcceptsTheFilterToo() async throws {
        let twenty: [Value] = (0..<20).map { .string("e\($0)") }
        let r = try await call(["events": .array(twenty), "detail": .string("detailed")],
                               source: FakeLogSource(lines: [Synthetic.line(offset: 0)]))
        XCTAssertEqual((r["events"] as? [String])?.count, 20)
    }

    func testTheUnknownKnownEventErrorNamesTheKnownEvents() {
        XCTAssertThrowsError(try MailLogQuery.parse(window.merging(["events": .array([.string("imap.nope")])]) { _, n in n }, now: now)) { error in
            XCTAssertTrue("\(error)".contains("imap.append_uid_received"), "\(error)")
        }
    }

    func testTheSchemaListsEvents() throws {
        guard case .object(let schema) = MailLogTool.definition.inputSchema,
              case .object(let properties)? = schema["properties"] else { return XCTFail("no properties") }
        XCTAssertNotNil(properties["events"])
        XCTAssertTrue(MailLogQuery.allowedParameters.contains("events"))
    }

    // MARK: - spec-example: mail-log-diagnostics / event-name filter matching

    private func kept(_ line: Data, _ value: String, file: StaticString = #filePath, line lineNo: UInt = #line) -> Bool {
        let results = Synthetic.results(run(FakeLogSource(lines: [line]), query([value])))
        if let first = results.first {
            XCTAssertEqual(first["event"] as? String, value, "a kept event shows exactly the filter value", file: file, line: lineNo)
        }
        return !results.isEmpty
    }

    func testMatchingTable() {
        // spec-example: mail-log-diagnostics / event-name filter matching
        let plain = Synthetic.line(offset: 0, format: template)
        XCTAssertTrue(kept(plain, template))
        XCTAssertFalse(kept(plain, "%@ received %lu new local message actions"), "case differs")
        XCTAssertFalse(kept(plain, "Received"), "substring")
        XCTAssertTrue(kept(receipt(0), "imap.append_uid_received"))
        XCTAssertFalse(kept(receipt(0), "%{public}@"), "a recognized receipt is not selectable by its raw template")
        XCTAssertTrue(kept(noise(0), "%{public}@"), "an unrecognized connection line shows its template")
        let withheld = Synthetic.line(offset: 0, format: withheldFormat, message: "Sending to someone@example.invalid now")
        XCTAssertFalse(kept(withheld, withheldFormat), "a withheld template is not addressable by its own text")
        XCTAssertTrue(kept(withheld, "<template withheld>"))
        let huge = Synthetic.line(offset: 0, format: "%{public}@", message: String(repeating: "x", count: 65_537))
        XCTAssertTrue(kept(huge, "%{public}@"), "an oversized message shows (and is selected by) its raw template")
        let composed = Synthetic.line(offset: 0, format: "Caf\u{E9} %@", message: "Caf\u{E9} x")
        XCTAssertTrue(kept(composed, "Caf\u{E9} %@"))
        XCTAssertFalse(kept(composed, "Cafe\u{301} %@"), "equality is by bytes, not by Unicode canonical equivalence")
    }

    func testFilterCombinesWithContainsInDetailedMode() {
        let lines = [
            Synthetic.line(offset: 0, format: template, message: "needle one", activity: 1),
            Synthetic.line(offset: 1, format: "Other %@", message: "needle two", activity: 2),
            Synthetic.line(offset: 2, format: template, message: "hay", activity: 3),
        ]
        let r = run(FakeLogSource(lines: lines), query([template], detail: .detailed, contains: "needle"))
        XCTAssertEqual(Synthetic.results(r).compactMap { $0["activity"] as? Int }, [1])
    }

    // MARK: - spec-example: mail-log-diagnostics / event-name filter paging

    func testPagingTable() {
        // spec-example: mail-log-diagnostics / event-name filter paging
        // three matching (activity 0, 2, 4) and two non-matching (1, 3) at the start millisecond, one more match later
        var lines = (0..<5).map { $0 % 2 == 0 ? receipt(0, activity: $0) : noise(0, activity: $0) }
        lines.append(receipt(1, activity: 9))
        let r = run(FakeLogSource(lines: lines), query(["imap.append_uid_received"], limit: 1, offset: 1))
        XCTAssertEqual(Synthetic.results(r).compactMap { $0["activity"] as? Int }, [2], "the non-matching 1 does not count toward the offset")
        XCTAssertEqual(r["stopped_by"] as? String, "limit")
        XCTAssertEqual(r["next_offset"] as? Int, 2)

        let scan = (0..<2).map { receipt(Double($0), activity: $0) } + (2..<6).map { noise(Double($0), activity: $0) }
        let s = run(FakeLogSource(lines: scan, end: .scanCap), query(["imap.append_uid_received"]))
        XCTAssertEqual(s["stopped_by"] as? String, "scan_cap")
        XCTAssertEqual(s["next_start"] as? String, Synthetic.iso(5), "the frontier counts events the filter rejected")
        XCTAssertEqual(s["next_offset"] as? Int, 0)

        let empty = run(FakeLogSource(lines: [noise(0), noise(1)]), query(["imap.append_uid_received"]))
        XCTAssertEqual(empty["status"] as? String, "no_events_in_window")
        XCTAssertEqual(empty["events"] as? [String], ["imap.append_uid_received"])
        XCTAssertTrue((empty["notice"] as? String ?? "").contains("event-name filter"), "\(empty["notice"] ?? "")")
        XCTAssertTrue((empty["notice"] as? String ?? "").contains("does not establish"))

        let unfiltered = run(FakeLogSource(lines: [noise(0)]), query(nil))
        XCTAssertTrue(unfiltered["events"] is NSNull, "events is null when not given")
        XCTAssertFalse((unfiltered["notice"] as? String ?? "").contains("event-name filter"))
    }

    func testTheEchoIsCarriedByAnUnavailableResponseToo() {
        let r = run(FakeLogSource(lines: [], end: .spawnFailed("boom")), query(["imap.append_uid_received"]))
        XCTAssertEqual(r["status"] as? String, "unavailable")
        XCTAssertEqual(r["events"] as? [String], ["imap.append_uid_received"])
    }

    // MARK: - scenarios

    func testScenario_theUploadReceiptIsFoundAmongNoise() {
        let lines = (0..<300).map { noise(Double($0) * 0.001, activity: $0) } + [receipt(1, activity: 999)]
        let r = run(FakeLogSource(lines: lines), query(["imap.append_uid_received"], limit: 1))
        XCTAssertEqual(Synthetic.results(r).compactMap { $0["activity"] as? Int }, [999])
        XCTAssertEqual(r["truncated"] as? Bool, false)
        XCTAssertEqual(Synthetic.results(r).first?["kind"] as? String, "known")
    }

    func testScenario_aWithheldTemplateIsNotAddressableByItsText() {
        let line = Synthetic.line(offset: 0, format: withheldFormat, message: "Sending to someone@example.invalid now")
        XCTAssertTrue(Synthetic.results(run(FakeLogSource(lines: [line]), query([withheldFormat]))).isEmpty)
        let r = Synthetic.results(run(FakeLogSource(lines: [line]), query(["<template withheld>"])))
        XCTAssertEqual(r.first?["event"] as? String, "<template withheld>")
        XCTAssertFalse(Synthetic.serialized(run(FakeLogSource(lines: [line]), query(["<template withheld>"]))).contains("someone@"))
    }

    func testScenario_aMisspelledKnownEventNameIsRejectedBeforeReading() async {
        await expectRejected(.array([.string("imap.append_uid_recieved")]), "misspelled known-event name")
    }

    func testTheFilterValuesNeverReachTheReader() {
        let source = FakeLogSource(lines: [receipt(0)])
        _ = run(source, query(["imap.append_uid_received"]))
        XCTAssertEqual(source.requests.count, 1)
        XCTAssertTrue(source.requests[0].categories.isEmpty, "the request carries only the window and the categories")
    }
}
