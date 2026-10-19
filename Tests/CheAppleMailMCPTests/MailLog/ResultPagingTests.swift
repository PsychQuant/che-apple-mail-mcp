import XCTest
@testable import CheAppleMailMCP

/// #465 — task 3.2: "Result limits, truncation, and paging", as amended by verify rounds 1 and 2.
///
/// The cursor under test is a POSITION, not a time: (`next_start`, `next_offset`) = "just after the
/// last event returned" — its time, and how many matching events at that millisecond have been
/// returned so far. Real logs put up to 169 events in one millisecond of one category; a time-only
/// cursor cannot point into such a group, so it either split the group and repeated it (round 2:
/// the size cap, findings 1/2/4/19) or stalled (round 1: `limit` = 1). With the offset every stop
/// reason — limit, size cap, scan cap, deadline — resumes exactly where it stopped.
final class ResultPagingTests: XCTestCase {

    private func run(_ source: FakeLogSource, _ query: MailLogQuery) -> [String: Any] {
        MailLogService(source: source, timeZone: Synthetic.taipei).run(query)
    }

    /// Pages through `lines` exactly the way a caller would: pass `next_start` back as `since` and
    /// `next_offset` as `offset`, keeping the window end.
    private func pageAll(_ lines: [Data], limit: Int, detail: MailLogDetail = .brief,
                         check: (([String: Any]) -> Void)? = nil) -> (entries: [String], pages: Int) {
        var start = Synthetic.base
        var offset = 0
        let end = Synthetic.base.addingTimeInterval(600)
        var all: [String] = []
        var pages = 0
        while pages < 200 {
            pages += 1
            let q = MailLogQuery(detail: detail, start: start, end: end, categories: [], contains: nil,
                                 redactIdentifiers: false, limit: limit, offset: offset)
            let r = run(FakeLogSource(lines: lines), q)
            check?(r)
            all += Synthetic.results(r).map { "\($0["time"] as? String ?? "?")#\($0["activity"] as? Int ?? -1)" }
            guard r["truncated"] as? Bool == true, let next = r["next_start"] as? String,
                  let nextOffset = r["next_offset"] as? Int,
                  let date = MailLogTime.parseISO8601WithOffset(next) else { return (all, pages) }
            XCTAssertFalse(date == start && nextOffset == offset, "page \(pages): the cursor did not move")
            start = date
            offset = nextOffset
        }
        XCTFail("paging did not terminate within 200 pages")
        return (all, pages)
    }

    private func burst() -> (lines: [Data], expected: [String]) {
        var lines: [Data] = []
        lines += (0..<3).map { Synthetic.line(offset: 0, activity: $0) }
        lines += (0..<40).map { Synthetic.line(offset: 1, activity: 100 + $0) }
        lines += (0..<5).map { Synthetic.line(offset: 2, activity: 200 + $0) }
        let expected = (0..<3).map { "\(Synthetic.iso(0))#\($0)" } + (0..<40).map { "\(Synthetic.iso(1))#\(100 + $0)" }
            + (0..<5).map { "\(Synthetic.iso(2))#\(200 + $0)" }
        return (lines, expected)
    }

    // MARK: limit / cursor

    func testMoreEventsThanTheLimit() {
        let source = FakeLogSource(lines: (0..<350).map { Synthetic.line(offset: Double($0)) })
        let r = run(source, Synthetic.query(limit: 200))
        let events = Synthetic.results(r)
        XCTAssertEqual(events.count, 200)
        XCTAssertEqual(r["returned"] as? Int, 200)
        XCTAssertEqual(r["limit"] as? Int, 200)
        XCTAssertEqual(r["truncated"] as? Bool, true)
        XCTAssertEqual(r["stopped_by"] as? String, "limit")
        XCTAssertEqual(events.first?["time"] as? String, Synthetic.iso(0))
        XCTAssertEqual(events.last?["time"] as? String, Synthetic.iso(199))
        XCTAssertEqual(r["next_start"] as? String, Synthetic.iso(199), "the cursor sits just after the last event returned")
        XCTAssertEqual(r["next_offset"] as? Int, 1, "one event at that millisecond has been returned")
        XCTAssertEqual(source.delivered, 201, "reading stops at limit + 1: that one event proves there is more")
    }

    func testExactlyTheLimit_isNotTruncated() {
        let source = FakeLogSource(lines: (0..<200).map { Synthetic.line(offset: Double($0)) })
        let r = run(source, Synthetic.query(limit: 200))
        XCTAssertEqual(Synthetic.results(r).count, 200)
        XCTAssertEqual(r["truncated"] as? Bool, false)
        XCTAssertTrue(r["stopped_by"] is NSNull)
        XCTAssertTrue(r["next_start"] is NSNull)
        XCTAssertTrue(r["next_offset"] is NSNull)
    }

    func testLimitOne_pagesThroughDistinctTimestampsWithoutStalling() {
        let lines = (0..<5).map { Synthetic.line(offset: Double($0), activity: $0) }
        let (entries, pages) = pageAll(lines, limit: 1)
        XCTAssertEqual(entries, (0..<5).map { "\(Synthetic.iso(Double($0)))#\($0)" })
        XCTAssertEqual(pages, 5)
    }

    func testALimitInsideABurstSplitsItExactly_withAnOffsetCursor() {
        // 3 at t=0, 40 at t=1, 5 at t=2. limit 10 falls in the middle of the burst at t=1.
        let r = run(FakeLogSource(lines: burst().lines), Synthetic.query(limit: 10))
        XCTAssertEqual(r["returned"] as? Int, 10, "a page never exceeds limit")
        XCTAssertEqual(r["truncated"] as? Bool, true)
        XCTAssertEqual(r["stopped_by"] as? String, "limit")
        XCTAssertEqual(r["next_start"] as? String, Synthetic.iso(1))
        XCTAssertEqual(r["next_offset"] as? Int, 7, "seven of the t=1 events have been returned")
    }

    func testPagingThroughBursts_returnsEveryEventExactlyOnce() {
        let (lines, expected) = burst()
        for limit in [1, 2, 7, 10, 43, 48, 100] {
            let (entries, _) = pageAll(lines, limit: limit)
            XCTAssertEqual(entries, expected, "limit \(limit): pages must concatenate to the unpaged result, exactly once each")
        }
    }

    /// Round 2, findings 1/2/4/19: the size cap cut a same-millisecond group and pointed the cursor
    /// at an event it had already returned, so a group larger than the cap came back identically on
    /// every call. 40 detailed events of 8,000 characters in ONE millisecond: about seven fit a page.
    func testABurstLargerThanTheSizeCap_pagesThroughExactlyOnce() {
        let big = String(repeating: "x", count: 8000)
        let lines = (0..<40).map { Synthetic.line(offset: 1, message: big, activity: $0) }
        let (entries, pages) = pageAll(lines, limit: 1000, detail: .detailed) { r in
            XCTAssertLessThanOrEqual(Synthetic.serialized(r).utf8.count, MailLogService.responseByteCap)
        }
        XCTAssertEqual(entries, (0..<40).map { "\(Synthetic.iso(1))#\($0)" })
        XCTAssertGreaterThan(pages, 4)
    }

    func testABurstEndingTheWindow_isPagedWithTheOffset() {
        let lines = (0..<40).map { Synthetic.line(offset: 1, activity: $0) }
        let r = run(FakeLogSource(lines: lines), Synthetic.query(limit: 10))
        XCTAssertEqual(r["returned"] as? Int, 10)
        XCTAssertEqual(r["truncated"] as? Bool, true)
        XCTAssertEqual(r["next_start"] as? String, Synthetic.iso(1))
        XCTAssertEqual(r["next_offset"] as? Int, 10)
        let (entries, pages) = pageAll(lines, limit: 10)
        XCTAssertEqual(entries, (0..<40).map { "\(Synthetic.iso(1))#\($0)" })
        XCTAssertEqual(pages, 4)
    }

    func testEventsAreReturnedInAscendingOrder_evenIfTheReaderEmittedThemSlightlyOutOfOrder() {
        let source = FakeLogSource(lines: [3, 1, 2, 0].map { Synthetic.line(offset: Double($0)) })
        let r = run(source, Synthetic.query())
        let times = Synthetic.results(r).compactMap { $0["time"] as? String }
        XCTAssertEqual(times, [0, 1, 2, 3].map { Synthetic.iso(Double($0)) })
        XCTAssertTrue((r["notice"] as? String ?? "").contains("out of time order"), "an inversion is reported, not hidden")
    }

    /// Round 2, findings 23/27: the early stop trusted arrival order. Once an inversion is seen the
    /// stop is switched off, and the cursor sits after the last RETURNED event, so an event that
    /// arrives late with an earlier time is still picked up by the next page.
    func testAnInversionAfterThePageFillsIsStillPickedUpByTheNextPage() {
        let lines = [0, 1, 2, 5, 3, 4].map { Synthetic.line(offset: Double($0), activity: $0) }
        let (entries, _) = pageAll(lines, limit: 3)
        XCTAssertEqual(entries, (0...5).map { "\(Synthetic.iso(Double($0)))#\($0)" })
    }

    // MARK: window

    func testEventsOutsideTheRequestedWindowAreDropped_closedInterval() {
        let source = FakeLogSource(lines: [-5, -0.001, 0, 10, 600, 600.001, 605].map { Synthetic.line(offset: $0) })
        let r = run(source, Synthetic.query())
        XCTAssertEqual(Synthetic.results(r).compactMap { $0["time"] as? String }, [0, 10, 600].map { Synthetic.iso($0) }, "both window edges are inclusive")
        XCTAssertEqual(r["skipped_lines"] as? Int, 0, "out-of-window is not a parse failure")
    }

    func testOutOfWindowEventsDoNotCountTowardTheLimit() {
        let lines = [Synthetic.line(offset: -1)] + (0..<3).map { Synthetic.line(offset: Double($0)) } + [Synthetic.line(offset: 700)]
        let r = run(FakeLogSource(lines: lines), Synthetic.query(limit: 3))
        XCTAssertEqual(Synthetic.results(r).count, 3)
        XCTAssertEqual(r["truncated"] as? Bool, false, "the 700 s event is outside the window, so there is no 'more'")
    }

    // MARK: early stop, size cap, scan frontier

    func testReadingStopsEarlyAgainstAnEndlessSource() {
        let source = FakeLogSource()
        source.endless = { i in Synthetic.line(offset: Double(i)) }
        let r = run(source, Synthetic.query(limit: 5))
        XCTAssertEqual(Synthetic.results(r).count, 5)
        XCTAssertEqual(source.delivered, 6)
        XCTAssertEqual(r["stopped_by"] as? String, "limit")
    }

    func testResponseSizeCap() {
        let big = String(repeating: "x", count: 8000)
        let source = FakeLogSource(lines: (0..<100).map { Synthetic.line(offset: Double($0), message: big) })
        let r = run(source, Synthetic.query(detail: .detailed, limit: 1000))
        let bytes = Synthetic.serialized(r).utf8.count
        XCTAssertLessThanOrEqual(bytes, MailLogService.responseByteCap)
        XCTAssertEqual(r["truncated"] as? Bool, true)
        XCTAssertEqual(r["stopped_by"] as? String, "size_cap")
        let returned = Synthetic.results(r).count
        XCTAssertGreaterThan(returned, 0)
        XCTAssertLessThan(returned, 100)
        XCTAssertEqual(r["returned"] as? Int, returned)
        XCTAssertEqual(r["next_start"] as? String, Synthetic.iso(Double(returned - 1)), "the cursor sits just after the last event that fit")
        XCTAssertEqual(r["next_offset"] as? Int, 1)
    }

    /// Claude Code persists any MCP result above 25,000 tokens to a file and warns above 10,000
    /// (code.claude.com/docs/en/mcp). Keep the cap well under a token budget, not at 256 KiB.
    func testTheByteCapStaysUnderTheHostsOutputBudget() {
        XCTAssertLessThanOrEqual(MailLogService.responseByteCap, 65_536)
    }

    func testScanCapReportsTheScanFrontierSoTheCallerCanContinue() {
        let lines = (0..<10).map { Synthetic.line(offset: Double($0), message: $0 == 2 ? "needle here" : "hay") }
        let r = run(FakeLogSource(lines: lines, end: .scanCap), Synthetic.query(detail: .detailed, contains: "needle"))
        XCTAssertEqual(Synthetic.results(r).count, 1)
        XCTAssertEqual(r["stopped_by"] as? String, "scan_cap")
        XCTAssertEqual(r["truncated"] as? Bool, true)
        XCTAssertEqual(r["next_start"] as? String, Synthetic.iso(9), "the frontier is the last event SCANNED, not the last one that matched")
        XCTAssertEqual(r["next_offset"] as? Int, 0, "no matching event at the frontier millisecond was returned")
    }

    /// Round 2, finding 5: a frontier cursor without an offset re-returned every event at the
    /// frontier millisecond.
    func testScanCapAfterReturningTheFrontierEvent_continuesWithoutRepeating() {
        let first = run(FakeLogSource(lines: (0..<5).map { Synthetic.line(offset: Double($0), activity: $0) }, end: .scanCap),
                        Synthetic.query())
        XCTAssertEqual(first["returned"] as? Int, 5)
        XCTAssertEqual(first["next_start"] as? String, Synthetic.iso(4))
        XCTAssertEqual(first["next_offset"] as? Int, 1)
        let all = (0..<10).map { Synthetic.line(offset: Double($0), activity: $0) }
        let q = MailLogQuery(detail: .brief, start: Synthetic.base.addingTimeInterval(4), end: Synthetic.base.addingTimeInterval(600),
                             categories: [], contains: nil, redactIdentifiers: false, limit: 200, offset: 1)
        let second = run(FakeLogSource(lines: all), q)
        XCTAssertEqual(Synthetic.results(second).compactMap { $0["activity"] as? Int }, [5, 6, 7, 8, 9])
    }

    func testDeadlineWithEveryScannedEventFilteredOut_isEmptyButNotUnavailable() {
        let lines = (0..<10).map { Synthetic.line(offset: Double($0), message: "hay") }
        let r = run(FakeLogSource(lines: lines, end: .deadline), Synthetic.query(detail: .detailed, contains: "needle"))
        XCTAssertEqual(r["status"] as? String, "no_events_in_window", "events WERE read; none matched")
        XCTAssertEqual(r["stopped_by"] as? String, "deadline")
        XCTAssertEqual(r["next_start"] as? String, Synthetic.iso(9))
        XCTAssertEqual(r["next_offset"] as? Int, 0)
        XCTAssertTrue((r["notice"] as? String ?? "").contains("not fully searched"))
    }

    /// Round 2, finding 14: events only from the reader's whole-second margin BEFORE the window, then
    /// the deadline. The window itself was never reached, so this is not an empty window.
    func testDeadlineBeforeAnyInWindowEvent_isUnavailable() {
        let r = run(FakeLogSource(lines: [Synthetic.line(offset: -0.5), Synthetic.line(offset: -0.2)], end: .deadline), Synthetic.query())
        XCTAssertEqual(r["status"] as? String, "unavailable")
        XCTAssertEqual(r["reason"] as? String, "deadline_exceeded")
    }

    func testScanCapBeforeAnyInWindowEvent_isUnavailable() {
        let r = run(FakeLogSource(lines: [Synthetic.line(offset: -0.5)], end: .scanCap), Synthetic.query())
        XCTAssertEqual(r["status"] as? String, "unavailable")
        XCTAssertEqual(r["reason"] as? String, "scan_cap_exceeded")
    }

    /// A stop that gets no further than the events the caller already has must not hand back the
    /// same cursor (a stall): it is reported as unavailable instead.
    func testAStopThatMakesNoProgressPastTheCursor_isUnavailable_notAStall() {
        let lines = (0..<3).map { Synthetic.line(offset: 0, activity: $0) }
        let q = MailLogQuery(detail: .brief, start: Synthetic.base, end: Synthetic.base.addingTimeInterval(600),
                             categories: [], contains: nil, redactIdentifiers: false, limit: 200, offset: 3)
        let r = run(FakeLogSource(lines: lines, end: .deadline), q)
        XCTAssertEqual(r["status"] as? String, "unavailable")
        XCTAssertEqual(r["reason"] as? String, "deadline_exceeded")
    }

    func testTheOffsetSkipsOnlyMatchingEventsAtExactlyTheStartMillisecond() {
        var lines = (0..<4).map { Synthetic.line(offset: 0, message: $0 == 1 ? "hay" : "needle \($0)", activity: $0) }
        lines.append(Synthetic.line(offset: 1, message: "needle 9", activity: 9))
        let q = MailLogQuery(detail: .detailed, start: Synthetic.base, end: Synthetic.base.addingTimeInterval(600),
                             categories: [], contains: "needle", redactIdentifiers: false, limit: 200, offset: 2)
        let r = run(FakeLogSource(lines: lines), q)
        XCTAssertEqual(Synthetic.results(r).compactMap { $0["activity"] as? Int }, [3, 9],
                       "matching events 0 and 2 are skipped; the non-matching 1 does not count toward the offset")
    }

    // MARK: filters

    func testContainsFilterIsAppliedInProcess_caseInsensitively_andNeverReachesTheSource() {
        let source = FakeLogSource(lines: [
            Synthetic.line(offset: 0, message: "Created APPEND action 5"),
            Synthetic.line(offset: 1, message: "something else"),
            Synthetic.line(offset: 2, message: "another append here"),
        ])
        let r = run(source, Synthetic.query(detail: .detailed, contains: "append"))
        XCTAssertEqual(Synthetic.results(r).compactMap { $0["message"] as? String }, ["Created APPEND action 5", "another append here"])
        XCTAssertEqual(source.requests.count, 1)
        XCTAssertTrue(source.requests[0].categories.isEmpty)
    }

    func testTheRequestCarriesTheQueryWindow() {
        let source = FakeLogSource()
        _ = run(source, Synthetic.query())
        XCTAssertEqual(source.requests.first?.start, Synthetic.base)
        XCTAssertEqual(source.requests.first?.end, Synthetic.base.addingTimeInterval(600))
    }

    /// Verify round 3, finding 1: the message cap counted Characters, and one Character can be dozens
    /// of UTF-8 bytes. 8,192 family emoji made one event about 200 KiB. The caps are now in bytes, so a
    /// single event — even the worst JSON-escaping case — always fits the response cap.
    func testOneEventCanNeverExceedTheCap_bytesNotCharacters() {
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 8192)
        let r1 = run(FakeLogSource(lines: [Synthetic.line(offset: 0, message: family)]), Synthetic.query(detail: .detailed))
        XCTAssertLessThanOrEqual(Synthetic.serialized(r1).utf8.count, MailLogService.responseByteCap)
        let event = Synthetic.results(r1).first
        XCTAssertLessThanOrEqual((event?["message"] as? String)?.utf8.count ?? .max, MailLogService.messageByteCap)
        XCTAssertEqual(event?["message_truncated"] as? Bool, true)

        let control = String(repeating: "\u{01}", count: 20_000)              // each escapes to six bytes
        let template = String(repeating: "👨‍👩‍👧‍👦", count: 400)
        let r2 = run(FakeLogSource(lines: [Synthetic.line(offset: 0, category: String(repeating: "c", count: 300), format: template, message: control)]),
                     Synthetic.query(detail: .detailed))
        XCTAssertLessThanOrEqual(Synthetic.serialized(r2).utf8.count, MailLogService.responseByteCap)
        XCTAssertEqual(Synthetic.results(r2).count, 1)
    }

    /// Verify round 3, findings 1/2: with an inversion seen during the read, the scan frontier is not
    /// trusted as a cursor — it could sit past a matching event that arrives later.
    func testAfterAnInversionTheEarlyStopCursorDoesNotJumpToTheFrontier() {
        let lines = [Synthetic.line(offset: 0, message: "needle"), Synthetic.line(offset: 5, message: "needle"),
                     Synthetic.line(offset: 3, message: "needle"), Synthetic.line(offset: 9, message: "hay")]
        let r = run(FakeLogSource(lines: lines, end: .deadline), Synthetic.query(detail: .detailed, contains: "needle"))
        XCTAssertEqual(Synthetic.results(r).count, 3)
        XCTAssertEqual(r["next_start"] as? String, Synthetic.iso(5), "after the last returned event, not the frontier at 9")
        XCTAssertEqual(r["next_offset"] as? Int, 1)
    }

    /// Verify round 4, finding 8: the one-millisecond window on a whole second, at the service.
    func testSinceEqualToUntilOnAWholeSecondReturnsThatMillisecond() {
        let lines = [Synthetic.line(offset: 0.999), Synthetic.line(offset: 1), Synthetic.line(offset: 1), Synthetic.line(offset: 1.001)]
        let t = Synthetic.base.addingTimeInterval(1)
        let q = MailLogQuery(detail: .brief, start: t, end: t, categories: [], contains: nil, redactIdentifiers: false, limit: 200)
        let r = run(FakeLogSource(lines: lines), q)
        XCTAssertEqual(r["returned"] as? Int, 2)
        XCTAssertEqual(r["truncated"] as? Bool, false)
    }

    /// Verify round 4, finding 8: with an inversion and NOTHING returned, the frontier is still the cursor —
    /// otherwise there is no progress at all.
    func testAfterAnInversionWithNothingReturnedTheFrontierIsStillTheCursor() {
        let lines = [Synthetic.line(offset: 0, message: "hay"), Synthetic.line(offset: 5, message: "hay"), Synthetic.line(offset: 3, message: "hay")]
        let r = run(FakeLogSource(lines: lines, end: .deadline), Synthetic.query(detail: .detailed, contains: "needle"))
        XCTAssertEqual(r["status"] as? String, "no_events_in_window")
        XCTAssertEqual(r["next_start"] as? String, Synthetic.iso(5))
        XCTAssertEqual(r["next_offset"] as? Int, 0)
    }
}
