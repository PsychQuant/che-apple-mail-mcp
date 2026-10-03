import XCTest
@testable import CheAppleMailMCP

/// #465 — time parsing/formatting. The tool's rule: every time that crosses
/// the boundary carries an explicit UTC offset (user is in UTC+8; a bare
/// string is silently read as another zone).
final class MailLogTimeTests: XCTestCase {
    private let taipei = TimeZone(secondsFromGMT: 8 * 3600)!

    func testFormat_isISO8601WithOffsetAndMilliseconds() {
        let t = MailLogTime(timeZone: taipei)
        XCTAssertEqual(t.format(Date(timeIntervalSince1970: 1790916146.431)),
                       "2026-10-02T12:42:26.431+08:00")
    }

    func testFormat_usesTheGivenZone() {
        let utc = MailLogTime(timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(utc.format(Date(timeIntervalSince1970: 1790916146.431)),
                       "2026-10-02T04:42:26.431Z")
    }

    func testParseISO_acceptsOffsetAndZ() {
        XCTAssertEqual(MailLogTime.parseISO8601WithOffset("2026-10-02T12:42:26+08:00")?.timeIntervalSince1970, 1790916146.0)
        XCTAssertEqual(MailLogTime.parseISO8601WithOffset("2026-10-02T04:42:26Z")?.timeIntervalSince1970, 1790916146.0)
        XCTAssertEqual(MailLogTime.parseISO8601WithOffset("2026-10-02T12:42:26.431+08:00")?.timeIntervalSince1970 ?? 0, 1790916146.431, accuracy: 0.001)
    }

    func testParseISO_rejectsTimestampsWithoutOffset() {
        XCTAssertNil(MailLogTime.parseISO8601WithOffset("2026-10-02T12:42:26"))
        XCTAssertNil(MailLogTime.parseISO8601WithOffset("2026-10-02 12:40:00"))
        XCTAssertNil(MailLogTime.parseISO8601WithOffset("2026-10-02"))
        XCTAssertNil(MailLogTime.parseISO8601WithOffset(""))
        XCTAssertNil(MailLogTime.parseISO8601WithOffset("yesterday"))
    }

    /// finding #3/#5: the ISO formatter ROUNDS, so any Date that carries sub-millisecond
    /// precision must be floored before it is printed — a cursor that rounds up skips events.
    func testFormat_floorsToMilliseconds_neverRoundsUp() {
        let t = MailLogTime(timeZone: taipei)
        XCTAssertEqual(t.format(Date(timeIntervalSince1970: 1790916146.9996)), "2026-10-02T12:42:26.999+08:00")
        XCTAssertEqual(t.format(Date(timeIntervalSince1970: 1790916146.4786)), "2026-10-02T12:42:26.478+08:00")
        XCTAssertEqual(t.format(Date(timeIntervalSince1970: 1790916146.0)), "2026-10-02T12:42:26.000+08:00")
        // Verify round 2, finding 16: a 1 µs tolerance turned a genuine 999 µs remainder into the next millisecond.
        XCTAssertEqual(t.format(Date(timeIntervalSince1970: 1790916146.802999)), "2026-10-02T12:42:26.802+08:00")
        XCTAssertEqual(t.format(Date(timeIntervalSince1970: 1790916146.802)), "2026-10-02T12:42:26.802+08:00")
    }

    /// The log carries microseconds; the tool's resolution is the millisecond, and it TRUNCATES.
    /// This was an undocumented side effect of DateFormatter; it is now explicit and pinned.
    func testParseLogTimestamp_truncatesToMillisecondsExactly() {
        func ms(_ s: String) -> Int? { MailLogTime.parseLogTimestamp(s).map { Int(($0.timeIntervalSince1970 * 1000).rounded()) } }
        XCTAssertEqual(ms("2026-10-02 12:42:26.802432+0800"), 1790916146802)
        XCTAssertEqual(ms("2026-10-02 12:42:26.802999+0800"), 1790916146802)
        XCTAssertEqual(ms("2026-10-02 12:42:26.478500+0800"), 1790916146478)
        XCTAssertEqual(ms("2026-10-02 12:42:26.999999+0800"), 1790916146999)
        XCTAssertEqual(ms("2026-10-02 12:42:26+0800"), 1790916146000, "a timestamp without a fraction is still accepted")
    }

    func testParseISO_truncatesFractionBeyondMilliseconds() {
        func ms(_ s: String) -> Int? { MailLogTime.parseISO8601WithOffset(s).map { Int(($0.timeIntervalSince1970 * 1000).rounded()) } }
        XCTAssertEqual(ms("2026-10-02T12:42:26.8026+08:00"), 1790916146802)
        XCTAssertEqual(ms("2026-10-02T12:42:26.999999+08:00"), 1790916146999)
        XCTAssertEqual(ms("2026-10-02T04:42:26.5Z"), 1790916146500)
    }

    /// verify round 1, finding #28: ISO8601DateFormatter silently NORMALIZES impossible dates
    /// (Feb 30 → Mar 2, 24:00 → next day). A window built from such a date is not the one asked for.
    func testParseISO_rejectsDatesTheCalendarDoesNotContain() {
        XCTAssertNil(MailLogTime.parseISO8601WithOffset("2026-02-30T12:00:00+08:00"))
        XCTAssertNil(MailLogTime.parseISO8601WithOffset("2026-10-02T24:00:00+08:00"))
        XCTAssertNil(MailLogTime.parseISO8601WithOffset("2026-13-01T00:00:00Z"))
        XCTAssertNil(MailLogTime.parseISO8601WithOffset("2026-10-02T12:60:00+08:00"))
        // valid edge cases still parse, including a non-whole-hour offset
        XCTAssertNotNil(MailLogTime.parseISO8601WithOffset("2028-02-29T12:00:00+08:00"))
        XCTAssertEqual(MailLogTime.parseISO8601WithOffset("2026-10-02T10:12:26+05:30")?.timeIntervalSince1970, 1790916146.0)
        XCTAssertEqual(MailLogTime.parseISO8601WithOffset("2026-10-01T23:42:26-05:00")?.timeIntervalSince1970, 1790916146.0)
    }

    func testParseLogTimestamp_readsTheCliShape() {
        XCTAssertEqual(MailLogTime.parseLogTimestamp("2026-10-02 12:42:26.478500+0800")?.timeIntervalSince1970 ?? 0,
                       1790916146.4785, accuracy: 0.001)
        XCTAssertNil(MailLogTime.parseLogTimestamp("garbage"))
    }
}
