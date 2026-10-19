import XCTest
@testable import CheAppleMailMCP

/// #465 — ndjson line parsing (task 1.1). Expected epochs are computed
/// independently of the code under test (Python `datetime.fromisoformat`).
final class NdjsonParserTests: XCTestCase {

    func testRecon463Fixture_yieldsNineEventsOneTrailerNoMalformed() throws {
        let parsed = try MailLogFixtures.lines("recon463.ndjson").map(NdjsonParser.parse)
        var events = 0, trailers = 0, malformed = 0
        for p in parsed {
            switch p {
            case .event: events += 1
            case .trailer: trailers += 1
            case .unrecognized: XCTFail("fixture line unexpectedly unrecognized")
            case .malformed: malformed += 1
            }
        }
        XCTAssertEqual(events, 9)
        XCTAssertEqual(trailers, 1, "the {count, finished} trailer is parseable but not an event")
        XCTAssertEqual(malformed, 0)
    }

    func testEventFields_areMapped() throws {
        let lines = try MailLogFixtures.lines("recon463.ndjson")
        guard case .event(let e) = NdjsonParser.parse(lines[3]) else { return XCTFail("expected an event") }
        XCTAssertEqual(e.subsystem, "com.apple.mail")
        XCTAssertEqual(e.category, "IMAPSyncActivity")
        XCTAssertEqual(e.formatString, "%@ Received %lu new local message actions")
        XCTAssertEqual(e.message, "[account-one@example.invalid - Drafts] <Sync> Received 1 new local message actions")
        XCTAssertEqual(e.process, "Mail", "process is the BASE NAME of processImagePath, never the full path")
        XCTAssertEqual(e.thread, 7001)
        XCTAssertEqual(e.activity, 9545744)
        // 2026-10-02 12:42:26.4785 +0800 == 1790916146.4785 (independent literal)
        XCTAssertEqual(e.time.timeIntervalSince1970, 1790916146.4785, accuracy: 0.001)
    }

    func testNonJSON_isMalformed() {
        XCTAssertEqual(NdjsonParser.parse(Data("this is not json".utf8)), .malformed)
        XCTAssertEqual(NdjsonParser.parse(Data("".utf8)), .malformed)
    }

    func testEventWithUnparseableTimestamp_isMalformed() {
        let line = #"{"timestamp":"garbage","subsystem":"com.apple.mail","category":"X","formatString":"f","eventMessage":"m","processImagePath":"/a/Mail","threadID":1,"activityIdentifier":0}"#
        XCTAssertEqual(NdjsonParser.parse(Data(line.utf8)), .malformed)
    }

    func testCountTrailer_isATrailer_notAnError() {
        XCTAssertEqual(NdjsonParser.parse(Data(#"{"count":3,"finished":1}"#.utf8)), .trailer)
    }

    /// If Apple renames `timestamp`, every line becomes one of these. They must be
    /// distinguishable from the trailer so the service can count them.
    func testJSONObjectThatIsNeitherEventNorTrailer_isUnrecognized() {
        XCTAssertEqual(NdjsonParser.parse(Data(#"{"time":"2026-10-02 12:42:26.431000+0800","category":"X"}"#.utf8)), .unrecognized)
        XCTAssertEqual(NdjsonParser.parse(Data(#"{"foo":1}"#.utf8)), .unrecognized)
        XCTAssertEqual(NdjsonParser.parse(Data("{}".utf8)), .unrecognized)
        // a trailer-shaped object with extra keys is not the trailer
        XCTAssertEqual(NdjsonParser.parse(Data(#"{"count":3,"finished":1,"extra":true}"#.utf8)), .unrecognized)
    }

    func testJSONThatIsNotAnObject_isMalformed() {
        XCTAssertEqual(NdjsonParser.parse(Data("[1,2,3]".utf8)), .malformed)
    }

    func testMissingOptionalFields_defaultInsteadOfFailing() {
        let line = #"{"timestamp":"2026-10-02 12:42:26.431000+0800"}"#
        guard case .event(let e) = NdjsonParser.parse(Data(line.utf8)) else { return XCTFail("expected an event") }
        XCTAssertEqual(e.category, "")
        XCTAssertEqual(e.formatString, "")
        XCTAssertEqual(e.activity, 0)
    }
}
