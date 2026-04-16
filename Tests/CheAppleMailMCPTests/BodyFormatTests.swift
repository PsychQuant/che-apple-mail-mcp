import XCTest
@testable import CheAppleMailMCP

final class BodyFormatTests: XCTestCase {

    func testInitRawValueOrNil_nilReturnsPlain() {
        let fmt = BodyFormat(rawValueOrNil: nil)
        XCTAssertEqual(fmt, .plain)
    }

    func testInitRawValueOrNil_emptyReturnsPlain() {
        let fmt = BodyFormat(rawValueOrNil: "")
        XCTAssertEqual(fmt, .plain)
    }

    func testInitRawValueOrNil_validValuesRoundtrip() {
        XCTAssertEqual(BodyFormat(rawValueOrNil: "plain"), .plain)
        XCTAssertEqual(BodyFormat(rawValueOrNil: "markdown"), .markdown)
        XCTAssertEqual(BodyFormat(rawValueOrNil: "html"), .html)
    }

    func testInitRawValueOrNil_unknownReturnsNil() {
        XCTAssertNil(BodyFormat(rawValueOrNil: "rtf"))
        XCTAssertNil(BodyFormat(rawValueOrNil: "HTML"), "match is case-sensitive")
        XCTAssertNil(BodyFormat(rawValueOrNil: " plain "), "no trimming — caller must normalize")
    }

    func testRawValueSurfacesEnumName() {
        XCTAssertEqual(BodyFormat.plain.rawValue, "plain")
        XCTAssertEqual(BodyFormat.markdown.rawValue, "markdown")
        XCTAssertEqual(BodyFormat.html.rawValue, "html")
    }
}
