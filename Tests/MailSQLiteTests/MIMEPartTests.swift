import XCTest
@testable import MailSQLite

final class MIMEPartTests: XCTestCase {

    // MARK: - Init and field access

    func testInitSetsAllFields() {
        let raw = Data([0x01, 0x02, 0x03])
        let decoded = Data([0x04, 0x05])
        let part = MIMEPart(
            headers: ["content-type": "image/png", "content-disposition": "attachment"],
            contentType: "image/png",
            contentTypeParams: ["name": "logo.png"],
            contentDisposition: "attachment",
            filename: "logo.png",
            rawBytes: raw,
            decodedData: decoded
        )

        XCTAssertEqual(part.headers["content-type"], "image/png")
        XCTAssertEqual(part.contentType, "image/png")
        XCTAssertEqual(part.contentTypeParams["name"], "logo.png")
        XCTAssertEqual(part.contentDisposition, "attachment")
        XCTAssertEqual(part.filename, "logo.png")
        XCTAssertEqual(part.rawBytes, raw)
        XCTAssertEqual(part.decodedData, decoded)
    }

    func testNilFilenameAndDispositionAllowed() {
        let part = MIMEPart(
            headers: ["content-type": "text/plain"],
            contentType: "text/plain",
            contentTypeParams: ["charset": "utf-8"],
            contentDisposition: nil,
            filename: nil,
            rawBytes: Data("hello".utf8),
            decodedData: Data("hello".utf8)
        )

        XCTAssertNil(part.contentDisposition)
        XCTAssertNil(part.filename)
        XCTAssertEqual(part.contentTypeParams["charset"], "utf-8")
    }

    // MARK: - Equatable

    func testEquatableSynthesized() {
        let a = MIMEPart(
            headers: ["content-type": "text/plain"],
            contentType: "text/plain",
            contentTypeParams: ["charset": "utf-8"],
            contentDisposition: nil,
            filename: nil,
            rawBytes: Data("x".utf8),
            decodedData: Data("x".utf8)
        )

        let b = MIMEPart(
            headers: ["content-type": "text/plain"],
            contentType: "text/plain",
            contentTypeParams: ["charset": "utf-8"],
            contentDisposition: nil,
            filename: nil,
            rawBytes: Data("x".utf8),
            decodedData: Data("x".utf8)
        )

        XCTAssertEqual(a, b)
    }

    func testNotEqualWhenDecodedDataDiffers() {
        let a = MIMEPart(
            headers: [:],
            contentType: "application/octet-stream",
            contentTypeParams: [:],
            contentDisposition: "attachment",
            filename: "a.bin",
            rawBytes: Data([0x01]),
            decodedData: Data([0x01])
        )

        let b = MIMEPart(
            headers: [:],
            contentType: "application/octet-stream",
            contentTypeParams: [:],
            contentDisposition: "attachment",
            filename: "a.bin",
            rawBytes: Data([0x01]),
            decodedData: Data([0x02])  // differs
        )

        XCTAssertNotEqual(a, b)
    }

    // MARK: - Sendable / value semantics

    // If MIMEPart is not Sendable, this function won't compile. That is the test.
    func testIsSendable() {
        let part = MIMEPart(
            headers: [:],
            contentType: "text/plain",
            contentTypeParams: [:],
            contentDisposition: nil,
            filename: nil,
            rawBytes: Data(),
            decodedData: Data()
        )
        assertSendable(part)
    }

    // MARK: - Eager decode contract

    // decodedData is a stored `let`, not a computed property. Guard against
    // future refactors that might make it lazy/computed by reflecting on the
    // Mirror: a stored property shows up as a child, a computed one doesn't.
    func testDecodedDataIsStoredPropertyNotComputed() {
        let part = MIMEPart(
            headers: [:],
            contentType: "text/plain",
            contentTypeParams: [:],
            contentDisposition: nil,
            filename: nil,
            rawBytes: Data(),
            decodedData: Data([0xff])
        )

        let mirror = Mirror(reflecting: part)
        let storedChildren = mirror.children.map { $0.label }
        XCTAssertTrue(
            storedChildren.contains("decodedData"),
            "decodedData must be a stored property (eager decode contract), not lazy/computed. "
            + "Found children: \(storedChildren.compactMap { $0 })"
        )
    }

    // Sendable assertion helper: function must be generic over `T: Sendable`
    // to force the compiler to check the conformance at the call site.
    private func assertSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
