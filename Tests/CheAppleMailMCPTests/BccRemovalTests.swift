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
            ("To: a@x.example\r\nBcc : b@x.example\r\n\r\nbody", "white space"),
            ("To: a@x.example\r\nSubject: s\r\n", "end of the header section"),
            ("To: a@x.example\r\n\n\r\nbody", "a line feed without a carriage return"),
        ]
        for (input, reason) in refused {
            XCTAssertThrowsError(try BccRemoval.strip(Data(input.utf8)), reason) { error in
                XCTAssertTrue("\(error)".contains(reason), "\(reason): \(error)")
            }
        }
    }
}
