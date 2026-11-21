import XCTest
@testable import CheAppleMailMCP

/// #742 — Requirement: The submitted message is the draft without its Bcc fields;
/// item 5 of Requirement: A draft is checked before it is submitted.
final class BccRemovalTests: XCTestCase {

    private func strip(_ text: String) throws -> String {
        String(decoding: try BccRemoval.strip(Data(text.utf8)), as: UTF8.self)
    }

    func testABccFieldIsRemoved_andEveryOtherByteIsKept() throws {
        let input = "From: me@x.example\r\nTo: a@x.example\r\nBcc: hidden@x.example\r\nSubject: s\r\n\r\nbody\r\nBcc: not a header\r\n"
        XCTAssertEqual(try strip(input),
                       "From: me@x.example\r\nTo: a@x.example\r\nSubject: s\r\n\r\nbody\r\nBcc: not a header\r\n")
    }

    func testAFoldedBccFieldIsRemovedWithItsContinuationLines_andEveryBccFieldGoes() throws {
        let input = "From: me@x.example\r\nBCC: one@x.example,\r\n two@x.example,\r\n\tthree@x.example\r\nTo: a@x.example\r\nbcc:\r\nX-Folded: a\r\n b\r\n\r\nbody"
        XCTAssertEqual(try strip(input), "From: me@x.example\r\nTo: a@x.example\r\nX-Folded: a\r\n b\r\n\r\nbody")
    }

    func testAMessageWithoutBccIsReturnedUnchanged() throws {
        let input = "From: me@x.example\r\nTo: a@x.example\r\nSubject: =?UTF-8?B?5Lit5paH?=\r\n\r\n\u{4E2D}\u{6587}"
        XCTAssertEqual(try strip(input), input)
    }

    func testTheBodyIsNotReadForHeaders_evenWithoutAFinalNewline() throws {
        let input = "To: a@x.example\r\n\r\nBcc: x\r\n\r\nBcc: y"
        XCTAssertEqual(try strip(input), input)
    }

    /// The draft is refused, not sent, when a line can hide a Bcc field from this reader.
    func testAHeaderThatCannotBeReadSafelyIsRefused() {
        let refused: [(String, String)] = [
            ("To: a@x.example\nBcc: b@x.example\r\n\r\nbody", "a line feed without a carriage return"),
            ("To: a@x.example\rBcc: b@x.example\r\n\r\nbody", "a carriage return without a line feed"),
            ("To: a@x.example\r\nResent-Bcc: b@x.example\r\n\r\nbody", "Resent-Bcc"),
            (" continued\r\nTo: a@x.example\r\n\r\nbody", "continuation line"),
            ("To: a@x.example\r\nnot a field\r\n\r\nbody", "not a header field"),
            ("To: a@x.example\r\nBcc : b@x.example\r\n\r\nbody", "outside printable ASCII"),
            ("To: a@x.example\r\n: b@x.example\r\n\r\nbody", "empty"),
            ("To: a@x.example\r\nB\u{1}cc: b@x.example\r\n\r\nbody", "outside printable ASCII"),
            ("To: a@x.example\r\nBc\u{00E7}: b@x.example\r\n\r\nbody", "outside printable ASCII"),
            ("To: a@x.example\r\nSubject: s\r\n", "end of the header section"),
            ("To: a@x.example\r\n\n\r\nbody", "a line feed without a carriage return"),
        ]
        for (input, reason) in refused {
            XCTAssertThrowsError(try BccRemoval.strip(Data(input.utf8)), reason) { error in
                XCTAssertTrue("\(error)".contains(reason), "\(reason): \(error)")
            }
        }
    }

    func testFieldValuesAreUnfolded_andAddressesCountedOutsideQuotesAndComments() throws {
        let input = "To: a@x.example,\r\n b@x.example\r\nSubject: s\r\n\r\n"
        let fields = try BccRemoval.fields(in: Data(input.utf8))
        XCTAssertEqual(fields.map(\.name), ["to", "subject"])
        XCTAssertEqual(fields[0].value, " a@x.example, b@x.example")
        XCTAssertEqual(BccRemoval.addressCount(inFieldValue: fields[0].value), 2)
        XCTAssertEqual(BccRemoval.addressCount(inFieldValue: #" "x@y" <a@x.example> (z@w)"#), 1)
        XCTAssertEqual(BccRemoval.addressCount(inFieldValue: #" "say \"hi@\"" <a@x.example>"#), 1)
    }

    /// A value must read plainly as addresses; a stray word between two is nil.
    func testAnAddressListIsCountedOnlyWhenEveryElementIsOneAddress() {
        XCTAssertEqual(BccRemoval.addressList(inFieldValue: " a@x.example, \"Doe, J\" <b@x.example>"), 2)
        XCTAssertEqual(BccRemoval.addressList(inFieldValue: " undisclosed-recipients:;"), 0)
        XCTAssertEqual(BccRemoval.addressList(inFieldValue: " Team: a@x.example, b@x.example;"), 2)
        XCTAssertNil(BccRemoval.addressList(inFieldValue: " a@x.example, junk"))
        XCTAssertNil(BccRemoval.addressList(inFieldValue: " a@x.example,"))
        XCTAssertNil(BccRemoval.addressList(inFieldValue: " :;"), "a group needs a name")
        XCTAssertNil(BccRemoval.addressList(inFieldValue: " a@b@x.example"))
    }

    func testTheFieldNamesAreListedLowercasedOncePerField() throws {
        let input = "From: me@x.example\r\nTO: a@x.example,\r\n b@x.example\r\nBcc: c@x.example\r\n\r\nTo: not a header"
        XCTAssertEqual(try BccRemoval.fieldNames(in: Data(input.utf8)), ["from", "to", "bcc"])
    }
}
