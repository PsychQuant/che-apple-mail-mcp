import XCTest
@testable import CheAppleMailMCP

/// #465 — task 2.4. Best-effort, three shapes only; the tests pin that
/// limitation as deliberately as the behavior.
final class RedactionTests: XCTestCase {

    func testSameEmailTwiceAndOneUUID() {
        var r = IdentifierRedactor()
        let out = r.redact("a alice@example.invalid b alice@example.invalid c 7F3A9C52-1B4E-4C8D-9A21-0E5D6F7A8B9C d")
        XCTAssertEqual(out, "a <email-1> b <email-1> c <uuid-1> d")
    }

    func testDistinctValuesGetDistinctNumbers_stableAcrossCalls() {
        var r = IdentifierRedactor()
        XCTAssertEqual(r.redact("x@example.invalid y@example.invalid"), "<email-1> <email-2>")
        XCTAssertEqual(r.redact("later y@example.invalid z@example.invalid"), "later <email-2> <email-3>",
                       "numbers are stable for the whole response, not per call")
    }

    func testEmailMatchingIsCaseInsensitive() {
        var r = IdentifierRedactor()
        XCTAssertEqual(r.redact("A@Example.Invalid a@example.invalid"), "<email-1> <email-1>")
    }

    func testMessageIDIsRedactedAsAWholeNotAsAnEmail() {
        var r = IdentifierRedactor()
        XCTAssertEqual(r.redact("id <FIX-1@example.invalid> from bob@example.invalid"),
                       "id <message-id-1> from <email-1>")
    }

    func testLowercaseUUID() {
        var r = IdentifierRedactor()
        XCTAssertEqual(r.redact("u 7f3a9c52-1b4e-4c8d-9a21-0e5d6f7a8b9c."), "u <uuid-1>.")
    }

    func testTrailingPunctuationIsNotSwallowed() {
        var r = IdentifierRedactor()
        XCTAssertEqual(r.redact("mail bob@example.invalid."), "mail <email-1>.")
    }

    func testStringsOutsideTheThreeShapesAreLeftAlone() {
        var r = IdentifierRedactor()
        // The documented limitation: display names and mailbox names are NOT redacted.
        let text = "[Google Work - Sent Items] <Sync> Task created"
        XCTAssertEqual(r.redact(text), text)
    }

    func testAlreadyRedactedTextIsStable() {
        var r = IdentifierRedactor()
        XCTAssertEqual(r.redact("<email-1> <uuid-1> <message-id-1>"), "<email-1> <uuid-1> <message-id-1>")
    }

    func testNothingToRedact() {
        var r = IdentifierRedactor()
        XCTAssertEqual(r.redact("plain text 123"), "plain text 123")
        XCTAssertEqual(r.redact(""), "")
    }

    /// finding #26/#34: the email pattern started a scan at every position of a long run of
    /// local-part characters and walked it to the end — quadratic. Bounded now.
    func testALongRunWithoutAnAtSignStaysLinear() {
        var r = IdentifierRedactor()
        let hostile = String(repeating: "a", count: 8192)
        let t0 = Date()
        XCTAssertEqual(r.redact(hostile), hostile)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
        let dotted = String(repeating: "a.", count: 4096)
        let t1 = Date()
        _ = r.redact(dotted + "@" + dotted)
        XCTAssertLessThan(Date().timeIntervalSince(t1), 1.0)
    }

    func testPatternNamesAreTheDocumentedClosedList() {
        XCTAssertEqual(IdentifierRedactor.patternNames, ["email", "uuid", "message-id"])
    }
}
