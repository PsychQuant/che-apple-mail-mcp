import XCTest
@testable import CheAppleMailMCP

/// #465 — task 2.2: the closed, one-entry allowlist. All positive and negative cases use the shape
/// Mail ACTUALLY logs (observed live), so a negative test cannot pass vacuously because the input
/// was never recognizable in the first place (verify round 1, finding #18).
final class KnownEventsTests: XCTestCase {
    private func event(category: String = "IMAPConnection", format: String = "%{public}@", message: String) -> MailLogEvent {
        MailLogEvent(time: Date(timeIntervalSince1970: 0), subsystem: "com.apple.mail", category: category,
                     formatString: format, message: message, process: "Mail", thread: 1, activity: 0)
    }

    private let prefix = "[Fixture.Server] <connection id:[Mailbox name=Fixture]> "
    private var realShape: String { prefix + "Read: 7 OK [APPENDUID (\n    1695,\n    902\n)]" }

    func testUploadReceiptInTheShapeMailActuallyLogsIsRecognized() {
        XCTAssertEqual(KnownEvents.name(for: event(message: realShape)), "imap.append_uid_received")
        XCTAssertEqual(KnownEvents.name(for: event(message: prefix + "Read: 1.2 OK [APPENDUID (1695, 902)]")), "imap.append_uid_received")
        XCTAssertEqual(KnownEvents.name(for: event(message: prefix + "Read: 3 OK [APPENDUID (\n  1695,\n  902,\n  903\n)]")), "imap.append_uid_received")
        XCTAssertEqual(KnownEvents.name(for: event(message: "Read: 7 OK [APPENDUID (1695, 902)]")), "imap.append_uid_received", "no connection prefix at all")
    }

    func testRFCWireFormIsNotRecognized_itWasNeverObserved() {
        XCTAssertNil(KnownEvents.name(for: event(message: prefix + "Read: 7 OK [APPENDUID 1695 902] Append completed")))
    }

    func testOtherPlaceholderOnlyEventsAreNotKnown() {
        XCTAssertNil(KnownEvents.name(for: event(message: prefix + "Write: 8 NOOP")))
    }

    func testSameTextInAnotherCategoryIsNotKnown() {
        XCTAssertNil(KnownEvents.name(for: event(category: "IMAPSyncActivity", message: realShape)))
    }

    func testTemplateWithLiteralTextIsNotKnown() {
        XCTAssertNil(KnownEvents.name(for: event(format: "Read: %@", message: realShape)))
    }

    func testTheWordWithoutTheResponseCode_isNotKnown() {
        XCTAssertNil(KnownEvents.name(for: event(message: prefix + #"Read: 3 * 1 FETCH (ENVELOPE ("Mon" "APPENDUID subject" NIL))"#)))
        XCTAssertNil(KnownEvents.name(for: event(message: "[APPENDUID (abc, def)]")))
        XCTAssertNil(KnownEvents.name(for: event(message: "Read: 7 OK [APPENDUID (1695)]")), "a receipt carries uidvalidity AND at least one uid")
        XCTAssertNil(KnownEvents.name(for: event(message: "Read: 7 OK [APPENDUID ()]")))
        XCTAssertNil(KnownEvents.name(for: event(message: "APPENDUID (1695, 902)")), "needs the surrounding brackets")
        XCTAssertNil(KnownEvents.name(for: event(message: "Read: 7 OK [APPENDUID (1695, a subject, 902)]")), "only numbers may sit inside the parentheses")
    }

    /// finding #2/#6/#12/#14/#46: the FULL response-code shape, planted in a subject that a FETCH
    /// response echoes, must not read as an upload receipt. A forged receipt tells a debugging
    /// caller that an upload happened when it did not.
    func testTheFullShapeEchoedInsideAFetchResponseIsNotKnown() {
        XCTAssertNil(KnownEvents.name(for: event(message: prefix + #"Read: * 5 FETCH (ENVELOPE ("Mon, 1 Jan" "Re: [APPENDUID (1, 2)]" NIL))"#)))
        // even a subject that imitates the WHOLE tagged line: the first "Read:" is Mail's own, and its tag is "*"
        XCTAssertNil(KnownEvents.name(for: event(message: prefix + #"Read: * 5 FETCH (ENVELOPE ("Read: 1.2 OK [APPENDUID (1, 2)]" NIL))"#)))
        XCTAssertNil(KnownEvents.name(for: event(message: prefix + "Read: * OK [APPENDUID (1, 2)]")), "an untagged response is not the receipt of OUR append")
    }

    func testOnlyAReadLineCountsAsAReceipt() {
        XCTAssertNil(KnownEvents.name(for: event(message: prefix + "Write: 7 OK [APPENDUID (1695, 902)]")))
        XCTAssertNil(KnownEvents.name(for: event(message: prefix + "7 OK [APPENDUID (1695, 902)]")))
    }

    /// Verify round 2, finding 7: the matcher took the first `Read: ` ANYWHERE. A Write line that
    /// echoes message text — an APPEND literal quoting a received mail — could supply it. The
    /// receipt must be the line's own `Read:`, right after the connection header.
    func testAReadPlantedInsideAWriteLineIsNotAReceipt() {
        XCTAssertNil(KnownEvents.name(for: event(message: prefix + "Write: 9 APPEND \"Drafts\" {120}\r\nSubject: Read: 1 OK [APPENDUID (1, 2)]")))
        XCTAssertNil(KnownEvents.name(for: event(message: "x Read: 1 OK [APPENDUID (1, 2)]")), "text before Read: that is not the header")
    }

    /// Real mailbox names contain `<` and `>` (653 of 88,636 Read lines in eight hours): the header
    /// ends at the first `]> `, not at the first `>`.
    func testAMailboxNameWithAngleBracketsStillFindsTheHeader() {
        let header = "[Fixture.Server] <connection id:[Mailbox name=a<1 b><c2>]> "
        XCTAssertEqual(KnownEvents.name(for: event(message: header + "Read: 7 OK [APPENDUID (1695, 902)]")), "imap.append_uid_received")
    }

    /// Verify round 3, findings 4/6: a FETCH literal can be split across reads, so a continuation
    /// chunk starts with the SENDER's bytes right after the header and `Read: `. Every one of the 27
    /// real receipts in 40 hours had a digits-and-dots tag and nothing after `)]`: the receipt is the
    /// whole chunk. Anything else is not a receipt.
    func testAContinuationChunkThatStartsWithForgedTextIsNotAReceipt() {
        XCTAssertNil(KnownEvents.name(for: event(message: prefix + "Read: AAAAAAAAAAAAAAAA OK [APPENDUID (1, 2)]")), "not a tag shape")
        XCTAssertNil(KnownEvents.name(for: event(message: prefix + "Read: 1.2 OK [APPENDUID (1, 2)] and the body continues")), "not the whole chunk")
        XCTAssertNil(KnownEvents.name(for: event(message: prefix + "Read: 12345678.12345678.1 OK [APPENDUID (1, 2)]")), "longer than any tag")
        XCTAssertEqual(KnownEvents.name(for: event(message: prefix + "Read: 8.161 OK [APPENDUID (\n    1695,\n    902\n)]\n")),
                       "imap.append_uid_received", "trailing whitespace is still the whole chunk")
    }
}
