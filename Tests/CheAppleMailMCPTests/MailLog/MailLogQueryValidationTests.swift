import XCTest
import MCP
@testable import CheAppleMailMCP

/// #465 — task 3.1: "Query window and parameter validation". `now` is injected so
/// every expected window is a literal (independent of the code under test).
final class MailLogQueryValidationTests: XCTestCase {
    /// 2026-10-02T12:43:26+08:00
    private let now = Date(timeIntervalSince1970: 1790916206)

    private func parse(_ args: [String: Value]) throws -> MailLogQuery {
        try MailLogQuery.parse(args, now: now)
    }

    private func assertRejected(_ args: [String: Value], mentions: String..., file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(args), file: file, line: line) { error in
            guard case MailError.invalidParameter(let message) = error else {
                return XCTFail("expected invalidParameter, got \(error)", file: file, line: line)
            }
            for needle in mentions {
                XCTAssertTrue(message.contains(needle), "message \(message.debugDescription) should mention \(needle.debugDescription)", file: file, line: line)
            }
        }
    }

    // MARK: defaults

    func testNoArguments_isLast10MinutesBriefLimit200() throws {
        let q = try parse([:])
        XCTAssertEqual(q.detail, .brief)
        XCTAssertEqual(q.end.timeIntervalSince1970, 1790916206)
        XCTAssertEqual(q.start.timeIntervalSince1970, 1790916206 - 600)
        XCTAssertEqual(q.limit, 200)
        XCTAssertTrue(q.categories.isEmpty)
        XCTAssertNil(q.contains)
        XCTAssertFalse(q.redactIdentifiers)
    }

    func testNullValuesAreTreatedAsAbsent() throws {
        let q = try parse(["last_minutes": .null, "limit": .null, "categories": .null, "detail": .null])
        XCTAssertEqual(q.limit, 200)
        XCTAssertEqual(q.start.timeIntervalSince1970, 1790916206 - 600)
    }

    // MARK: spec "validation boundaries" example table

    func testLastMinutesBoundaries() throws {
        assertRejected(["last_minutes": .int(0)], mentions: "last_minutes", "1", "60")
        XCTAssertEqual(try parse(["last_minutes": .int(60)]).start.timeIntervalSince1970, 1790916206 - 3600)
        assertRejected(["last_minutes": .int(61)], mentions: "last_minutes")
    }

    func testSpanLongerThan60Minutes_isRejected() {
        assertRejected(["since": .string("2026-10-02T12:00:00+08:00"), "until": .string("2026-10-02T13:30:00+08:00")],
                       mentions: "60 minutes")
    }

    func testAround_defaultsToRadius60() throws {
        let q = try parse(["around": .string("2026-10-02T12:42:26+08:00")])
        XCTAssertEqual(q.start.timeIntervalSince1970, 1790916146 - 60)
        XCTAssertEqual(q.end.timeIntervalSince1970, 1790916146 + 60)
    }

    func testAround_radiusBounds() throws {
        let t = Value.string("2026-10-02T12:42:26+08:00")
        assertRejected(["around": t, "radius_seconds": .int(0)], mentions: "radius_seconds")
        let q = try parse(["around": t, "radius_seconds": .int(1800)])
        XCTAssertEqual(q.end.timeIntervalSince1970 - q.start.timeIntervalSince1970, 3600)
        assertRejected(["around": t, "radius_seconds": .int(1801)], mentions: "radius_seconds")
    }

    func testCategories() throws {
        XCTAssertEqual(try parse(["categories": .array([.string("IMAPSyncActivity")])]).categories.map(\.value), ["IMAPSyncActivity"])
        assertRejected(["categories": .array([.string("a\"b")])], mentions: "category")
        assertRejected(["categories": .array([])], mentions: "categories")
        assertRejected(["categories": .string("IMAPSyncActivity")], mentions: "categories", "array")
        assertRejected(["categories": .array([.int(5)])], mentions: "categories")
        let many = (0..<21).map { Value.string("c\($0)") }
        assertRejected(["categories": .array(many)], mentions: "categories", "20")
    }

    func testLimitBounds() throws {
        assertRejected(["limit": .int(0)], mentions: "limit")
        XCTAssertEqual(try parse(["limit": .int(1000)]).limit, 1000)
        assertRejected(["limit": .int(1001)], mentions: "limit")
    }

    // MARK: spec scenarios

    func testNaiveTimestampRejected_namingTheRequiredFormat() {
        assertRejected(["since": .string("2026-10-02 12:40:00")], mentions: "since", "ISO 8601", "offset")
        assertRejected(["since": .string("2026-10-02T12:40:00")], mentions: "offset")
        assertRejected(["around": .string("2026-10-02T12:40:00")], mentions: "around", "offset")
        assertRejected(["since": .string("2026-10-02T12:00:00+08:00"), "until": .string("2026-10-02T12:30:00")], mentions: "until", "offset")
    }

    func testSubstringFilterAndRedactionAreNotAvailableInBrief() {
        assertRejected(["contains": .string("x")], mentions: "contains", "detailed")
        assertRejected(["detail": .string("brief"), "contains": .string("x")], mentions: "contains")
        assertRejected(["redact_identifiers": .bool(true)], mentions: "redact_identifiers", "detailed")
        assertRejected(["redact_identifiers": .bool(false)], mentions: "redact_identifiers", "detailed")
    }

    func testDetailedAcceptsContainsAndRedaction() throws {
        let q = try parse(["detail": .string("detailed"), "contains": .string("APPEND"), "redact_identifiers": .bool(true)])
        XCTAssertEqual(q.detail, .detailed)
        XCTAssertEqual(q.contains, "APPEND")
        XCTAssertTrue(q.redactIdentifiers)
    }

    func testTwoWindowFormsCombined() {
        assertRejected(["last_minutes": .int(5), "around": .string("2026-10-02T12:42:26+08:00")], mentions: "one window")
        assertRejected(["last_minutes": .int(5), "since": .string("2026-10-02T12:00:00+08:00")], mentions: "one window")
        assertRejected(["around": .string("2026-10-02T12:42:26+08:00"), "since": .string("2026-10-02T12:00:00+08:00")], mentions: "one window")
    }

    func testDependentParameters() {
        assertRejected(["until": .string("2026-10-02T12:30:00+08:00")], mentions: "until", "since")
        assertRejected(["radius_seconds": .int(30)], mentions: "radius_seconds", "around")
    }

    func testSinceWithoutUntil_endsAtNow() throws {
        let q = try parse(["since": .string("2026-10-02T12:33:26+08:00")])
        XCTAssertEqual(q.start.timeIntervalSince1970, 1790916206 - 600)
        XCTAssertEqual(q.end.timeIntervalSince1970, 1790916206)
    }

    func testSinceMustNotBeAfterUntil() {
        assertRejected(["since": .string("2026-10-02T12:30:00.001+08:00"), "until": .string("2026-10-02T12:30:00+08:00")], mentions: "after")
    }

    /// Round 2, finding 12: the window is a closed interval, so the cursor can equal window.end and the
    /// documented continuation (since=next_start, until=window.end) must be accepted.
    func testSinceEqualToUntil_isAZeroWidthClosedWindow() throws {
        let q = try parse(["since": .string("2026-10-02T12:30:00.250+08:00"), "until": .string("2026-10-02T12:30:00.250+08:00")])
        XCTAssertEqual(q.start, q.end)
    }

    func testOffset() throws {
        let since = Value.string("2026-10-02T12:30:00.250+08:00")
        XCTAssertEqual(try parse(["since": since]).offset, 0)
        XCTAssertEqual(try parse(["since": since, "offset": .int(7)]).offset, 7)
        assertRejected(["offset": .int(1)], mentions: "offset", "since")
        assertRejected(["last_minutes": .int(5), "offset": .int(1)], mentions: "offset", "since")
        assertRejected(["since": since, "offset": .int(-1)], mentions: "offset")
        assertRejected(["since": since, "offset": .string("3")], mentions: "offset")
    }

    /// Round 2, finding 22: a window computed from `now` was printed floored to the millisecond but
    /// filtered with the unfloored value, so the stated start and the applied start differed.
    func testComputedWindowsAreTruncatedToTheMillisecond() throws {
        let preciseNow = Date(timeIntervalSince1970: 1790916206.4789)
        let q = try MailLogQuery.parse(["last_minutes": .int(1)], now: preciseNow)
        XCTAssertEqual(q.end.timeIntervalSince1970, 1790916206.478, accuracy: 1e-6)
        XCTAssertEqual(q.start.timeIntervalSince1970, 1790916146.478, accuracy: 1e-6)
        let a = try MailLogQuery.parse(["around": .string("2026-10-02T12:42:26.4+08:00"), "radius_seconds": .int(1)], now: preciseNow)
        XCTAssertEqual(a.start.timeIntervalSince1970, 1790916145.4, accuracy: 1e-6)
    }

    func testZSuffixIsAccepted() throws {
        let q = try parse(["since": .string("2026-10-02T04:33:26Z")])
        XCTAssertEqual(q.start.timeIntervalSince1970, 1790916206 - 600)
    }

    // MARK: silent-failure guards (Confused Developer)

    func testUnknownParameterIsRejected_notSilentlyIgnored() {
        assertRejected(["contain": .string("x"), "detail": .string("detailed")], mentions: "contain", "unknown")
        assertRejected(["last_minute": .int(5)], mentions: "last_minute")
    }

    func testTypeConfusionIsRejected() {
        assertRejected(["last_minutes": .string("12")], mentions: "last_minutes", "integer")
        assertRejected(["limit": .bool(true)], mentions: "limit")
        assertRejected(["limit": .double(2.5)], mentions: "limit", "integer")
        assertRejected(["detail": .int(1)], mentions: "detail")
        assertRejected(["detail": .string("verbose")], mentions: "detail", "brief", "detailed")
        assertRejected(["detail": .string("detailed"), "redact_identifiers": .string("true")], mentions: "redact_identifiers", "boolean")
    }

    func testIntegralDoubleIsAcceptedAsInteger() throws {
        XCTAssertEqual(try parse(["limit": .double(50)]).limit, 50)
    }

    func testContainsBounds() {
        assertRejected(["detail": .string("detailed"), "contains": .string("")], mentions: "contains")
        assertRejected(["detail": .string("detailed"), "contains": .string(String(repeating: "x", count: 201))], mentions: "contains", "200")
    }
}
