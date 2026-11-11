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

    /// The error must be the invalid-parameter error, and its message must name the rule this row breaks:
    /// every row isolates one rule, so another error thrown first would not pass for it (verify round 1, row 4).
    private func expectRejected(_ value: Value, _ reason: String, file: StaticString = #filePath, line: UInt = #line) async {
        let source = FakeLogSource(lines: [Synthetic.line(offset: 0)])
        do {
            _ = try await call(["events": value], source: source)
            XCTFail("expected an invalid-parameter error naming: \(reason)", file: file, line: line)
        } catch MailError.invalidParameter(let message) {
            XCTAssertTrue(message.contains(reason), "error \(message.debugDescription) must name: \(reason)", file: file, line: line)
        } catch {
            XCTFail("expected MailError.invalidParameter, got \(error)", file: file, line: line)
        }
        XCTAssertTrue(source.requests.isEmpty, "the log reader must not be started: \(reason)", file: file, line: line)
    }

    /// Accepted: the normalized values are the ones the query keeps, and the response reports how many there are.
    private func expectAccepted(_ value: Value, normalized: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        let parsed = try MailLogQuery.parse(window.merging(["events": value]) { _, new in new }, now: now)
        XCTAssertEqual(parsed.events, normalized, file: file, line: line)
        let r = try await call(["events": value], source: FakeLogSource(lines: [Synthetic.line(offset: 0)]))
        XCTAssertEqual(r["event_filter_count"] as? Int, normalized.count, file: file, line: line)
    }

    func testValidationTable() async throws {
        // spec-example: mail-log-diagnostics / event-name filter validation
        try await expectAccepted(.array([.string("imap.append_uid_received")]), normalized: ["imap.append_uid_received"])
        try await expectAccepted(.array([.string(template)]), normalized: [template])
        try await expectAccepted(.array([.string("<template withheld>")]), normalized: ["<template withheld>"])
        await expectRejected(.array([.string("imap.append_uid_recieved")]), "unknown known-event name")
        await expectRejected(.array([.string("IMAP.append_uid_received")]), "unknown known-event name")
        await expectRejected(.array([.string("imap.\u{301}append_uid_received")]), "unknown known-event name")
        await expectRejected(.array([]), "must not be empty")
        await expectRejected(.array((0..<21).map { .string("e\($0)") }), "at most 20")
        await expectRejected(.array([.string("")]), "1 to 1024 bytes")
        await expectRejected(.array([.string(String(repeating: "é", count: 512) + "x")]), "1 to 1024 bytes")
        try await expectAccepted(.array([.string(String(repeating: "é", count: 512))]),
                                 normalized: [String(repeating: "é", count: 512)])
        await expectRejected(.string("imap.append_uid_received"), "must be an array")
        await expectRejected(.array([.int(1)]), "only strings")
        try await expectAccepted(.array([.string("a"), .string("a"), .string("b")]), normalized: ["a", "b"])
        try await expectAccepted(.array([.string("Caf\u{E9} %@"), .string("Cafe\u{301} %@")]),
                                 normalized: ["Caf\u{E9} %@", "Cafe\u{301} %@"])
    }

    func testTwentyEntriesAreAccepted_andDetailedModeAcceptsTheFilterToo() async throws {
        let twenty: [Value] = (0..<20).map { .string("e\($0)") }
        let r = try await call(["events": .array(twenty), "detail": .string("detailed")],
                               source: FakeLogSource(lines: [Synthetic.line(offset: 0)]))
        XCTAssertEqual(r["event_filter_count"] as? Int, 20)
    }

    /// Verify round 1, row 2: the response must stay within the byte cap with the largest filter allowed — the
    /// values are not echoed (an echo of 20 × 1024 control characters alone was 122,952 bytes).
    func testTheLargestFilterKeepsEveryResponseWithinTheCap() throws {
        let huge: [String] = (0..<20).map { String(repeating: "\u{01}", count: 1023) + "\($0 % 10)" }
        // nothing matches, window read to its end: an answer, not a size_cap stop
        let empty = run(FakeLogSource(lines: [noise(0), noise(1)]), query(huge))
        XCTAssertLessThanOrEqual(Synthetic.serialized(empty).utf8.count, MailLogService.responseByteCap)
        XCTAssertEqual(empty["status"] as? String, "no_events_in_window")
        XCTAssertTrue(empty["stopped_by"] is NSNull)
        XCTAssertEqual(empty["truncated"] as? Bool, false)
        XCTAssertFalse(Synthetic.serialized(empty).contains("\\u0001"), "caller text is not echoed")
        // a scan_cap stop keeps its scan-frontier cursor
        let scan = run(FakeLogSource(lines: (0..<6).map { noise(Double($0), activity: $0) }, end: .scanCap), query(huge))
        XCTAssertEqual(scan["stopped_by"] as? String, "scan_cap")
        XCTAssertEqual(scan["next_start"] as? String, Synthetic.iso(5))
        // an unavailable answer stays small too
        let down = run(FakeLogSource(lines: [], end: .spawnFailed("boom")), query(huge))
        XCTAssertLessThanOrEqual(Synthetic.serialized(down).utf8.count, 4096)
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
        // At the start millisecond, in reader order: non-matching 1, matching 0, non-matching 3, matching 2, matching 4;
        // one more match later. The group STARTS with a non-matching event, so an offset consumed before the filter
        // would skip event 1 and return 0, which the previous page already delivered (verify round 1, row 3).
        var lines = [noise(0, activity: 1), receipt(0, activity: 0), noise(0, activity: 3), receipt(0, activity: 2), receipt(0, activity: 4)]
        lines.append(receipt(1, activity: 9))
        let r = run(FakeLogSource(lines: lines), query(["imap.append_uid_received"], limit: 1, offset: 1))
        XCTAssertEqual(Synthetic.results(r).compactMap { $0["activity"] as? Int }, [2], "the non-matching events do not count toward the offset")
        XCTAssertEqual(r["stopped_by"] as? String, "limit")
        XCTAssertEqual(r["next_offset"] as? Int, 2)

        let scan = (0..<2).map { receipt(Double($0), activity: $0) } + (2..<6).map { noise(Double($0), activity: $0) }
        let s = run(FakeLogSource(lines: scan, end: .scanCap), query(["imap.append_uid_received"]))
        XCTAssertEqual(s["stopped_by"] as? String, "scan_cap")
        XCTAssertEqual(s["next_start"] as? String, Synthetic.iso(5), "the frontier counts events the filter rejected")
        XCTAssertEqual(s["next_offset"] as? Int, 0)

        let empty = run(FakeLogSource(lines: [noise(0), noise(1)]), query(["imap.append_uid_received"]))
        XCTAssertEqual(empty["status"] as? String, "no_events_in_window")
        XCTAssertEqual(empty["event_filter_count"] as? Int, 1)
        XCTAssertTrue((empty["notice"] as? String ?? "").contains("event-name filter"), "\(empty["notice"] ?? "")")
        XCTAssertTrue((empty["notice"] as? String ?? "").contains("does not establish"))

        let unfiltered = run(FakeLogSource(lines: [noise(0)]), query(nil))
        XCTAssertTrue(unfiltered["event_filter_count"] is NSNull, "event_filter_count is null when not given")
        XCTAssertFalse((unfiltered["notice"] as? String ?? "").contains("event-name filter"))
    }

    func testTheCountIsCarriedByAnUnavailableResponseToo() {
        let r = run(FakeLogSource(lines: [], end: .spawnFailed("boom")), query(["imap.append_uid_received"]))
        XCTAssertEqual(r["status"] as? String, "unavailable")
        XCTAssertEqual(r["event_filter_count"] as? Int, 1)
    }

    /// Verify round 1, row 10: every name the matcher can return is one the validator accepts.
    func testEveryKnownEventNameIsAcceptedByTheValidator() throws {
        let recognized = KnownEvents.name(for: MailLogEvent(time: Synthetic.base, subsystem: "com.apple.mail", category: "IMAPConnection",
                                                            formatString: "%{public}@", message: receiptMessage, process: "Mail", thread: 1, activity: 0))
        XCTAssertEqual(recognized, KnownEvents.appendUIDReceived)
        XCTAssertEqual(KnownEvents.names, [KnownEvents.appendUIDReceived], "the list is closed: exactly one entry")
        for name in KnownEvents.names {
            XCTAssertEqual(try MailLogQuery.parse(window.merging(["events": .array([.string(name)])]) { _, n in n }, now: now).events, [name])
        }
    }

    func testTheResponseCarriesNoCallerText_inEitherDetail() {
        for detail in [MailLogDetail.brief, .detailed] {
            let r = run(FakeLogSource(lines: [noise(0)]), query(["someone@example.invalid"], detail: detail))
            XCTAssertFalse(Synthetic.serialized(r).contains("someone@"), "\(detail): the filter values are not echoed")
        }
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
        await expectRejected(.array([.string("imap.append_uid_recieved")]), "unknown known-event name")
    }

    func testTheFilterValuesNeverReachTheReader() {
        let source = FakeLogSource(lines: [receipt(0)])
        _ = run(source, query(["imap.append_uid_received"]))
        XCTAssertEqual(source.requests.count, 1)
        XCTAssertTrue(source.requests[0].categories.isEmpty, "the request carries only the window and the categories")
    }
}
