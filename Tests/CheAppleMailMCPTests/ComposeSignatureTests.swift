import XCTest
import MCP
@testable import CheAppleMailMCP

final class ComposeSignatureTests: XCTestCase {
    func test_parser_and_reserved_names_are_unambiguous() throws {
        XCTAssertEqual(try ComposeSignatureSelection.parse(nil), .mailDefault)
        XCTAssertEqual(try ComposeSignatureSelection.parse(.object(["mode": .string("none")])), .init(mode: .none))
        XCTAssertEqual(try ComposeSignatureSelection.parse(.object(["mode": .string("named"), "name": .string("none")])), .init(mode: .named, name: "none"))
        for value: Value in [.null, .string("none"), .object([:]), .object(["mode": .string("named")]),
                             .object(["mode": .string("none"), "name": .string("x")]),
                             .object(["mode": .string("named"), "name": .string("\n")]),
                             .object(["mode": .string("mail_default"), "extra": .bool(true)])] {
            XCTAssertThrowsError(try ComposeSignatureSelection.parse(value))
        }
    }

    func test_encoded_receipt_handles_arbitrary_names_and_bcc_suffix_order() throws {
        let name = "簽名 ] [bcc-field-revealed] POSTDISPATCH: \"name\""
        let receipt = ComposeSignatureReceipt(mode: .named, selection: name, selectionVerified: true, selectionApplied: true)
        let encoded = try JSONEncoder().encode(receipt).base64EncodedString()
        var result = "Draft created" + ComposeSignatureReceipt.marker + encoded + "]" + bccFieldRevealedScriptTag
        XCTAssertTrue(result.hasSuffix(bccFieldRevealedScriptTag))
        result.removeLast(bccFieldRevealedScriptTag.count)
        let parsed = try ComposeSignatureReceipt.extract(from: &result, requested: .init(mode: .named, name: name))
        XCTAssertEqual(parsed, receipt)
        XCTAssertEqual(result, "Draft created")
        XCTAssertTrue(receipt.disclosure.contains("body_insertion_verified: false"))
    }

    func test_explicit_missing_or_mismatched_receipt_refuses() throws {
        var result = "Draft created"
        XCTAssertThrowsError(try ComposeSignatureReceipt.extract(from: &result, requested: .init(mode: .none)))
        XCTAssertNil(try ComposeSignatureReceipt.extract(from: &result, requested: .mailDefault))
        let wrong = ComposeSignatureReceipt(mode: .named, selection: "wrong", selectionVerified: true, selectionApplied: true)
        result += ComposeSignatureReceipt.marker + (try JSONEncoder().encode(wrong).base64EncodedString()) + "]"
        XCTAssertThrowsError(try ComposeSignatureReceipt.extract(from: &result, requested: .init(mode: .named, name: "wanted")))
    }
}
