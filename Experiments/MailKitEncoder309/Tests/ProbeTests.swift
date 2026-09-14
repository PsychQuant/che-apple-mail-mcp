import XCTest
import MailKit

final class ProbeTests: XCTestCase {
    let runID = "8EDAFB10-5AB6-49BC-9CEC-6D5F58AAB0E0"
    let address = "probe@example.invalid"

    func testDisabledOrMalformedConfigurationCannotMatch() {
        XCTAssertNil(ProbeConfiguration(recipient: "", runID: runID))
        XCTAssertNil(ProbeConfiguration(recipient: address, runID: ""))
        XCTAssertNil(ProbeConfiguration(recipient: "A <probe@example.invalid>", runID: runID))
        XCTAssertNil(ProbeConfiguration(recipient: "a\r\nb@example.invalid", runID: runID))
    }

    func testOnlyExactSelfAddressSubjectAndSingleRecipientMatch() throws {
        let c = try XCTUnwrap(ProbeConfiguration(recipient: address, runID: runID))
        XCTAssertTrue(c.matches(subject: c.subject, sender: address, recipients: [address]))
        XCTAssertFalse(c.matches(subject: c.subject + "other", sender: address, recipients: [address]))
        XCTAssertFalse(c.matches(subject: c.subject, sender: "other@example.invalid", recipients: [address]))
        XCTAssertFalse(c.matches(subject: c.subject, sender: address, recipients: [address, address]))
        XCTAssertFalse(c.matches(subject: c.subject, sender: address, recipients: []))
        XCTAssertFalse(c.matches(subject: c.subject, sender: nil, recipients: [address]))
        XCTAssertFalse(c.matches(subject: c.subject, sender: address, recipients: [nil]))
        XCTAssertFalse(c.matches(subject: c.subject, sender: address, recipients: ["other@example.invalid"]))
    }

    func testRewriteChangesOnlyOneBodyMarkerAndPreservesHeaders() throws {
        let c = try XCTUnwrap(ProbeConfiguration(recipient: address, runID: runID))
        let header = "Subject: \(c.originalMarker)\r\nContent-Type: text/plain\r\n\r\n"
        let input = Data((header + c.originalMarker + "\r\n").utf8)
        let result = try XCTUnwrap(c.replacement(in: input))
        XCTAssertEqual(String(decoding: result, as: UTF8.self), header + c.replacementMarker + "\r\n")
    }

    func testMissingDuplicateEncodedOrOversizedBodyRefusesReplacement() throws {
        let c = try XCTUnwrap(ProbeConfiguration(recipient: address, runID: runID))
        for text in ["Subject: \(c.originalMarker)", "Subject: \(c.originalMarker)\r\n\r\nnone",
                     "Content-Type: text/plain\r\n\r\n" + c.originalMarker + c.originalMarker,
                     "Content-Type: text/plain\r\n\r\n" + Data(c.originalMarker.utf8).base64EncodedString()] {
            XCTAssertNil(c.replacement(in: Data(text.utf8)))
        }
        XCTAssertNil(c.replacement(in: Data(repeating: 65, count: 1_048_577)))
    }

    func testMultipartAttachmentSignedAndEncodedMIMEAreRefused() throws {
        let c = try XCTUnwrap(ProbeConfiguration(recipient: address, runID: runID))
        let cases = [
            "Content-Type: multipart/mixed; boundary=probe\r\n\r\n--probe\r\nContent-Disposition: attachment; filename=\"" + c.originalMarker + "\"\r\n\r\nabc\r\n--probe--",
            "Content-Type: multipart/mixed; boundary=" + c.originalMarker + "\r\n\r\n--" + c.originalMarker + "--",
            "Content-Type: text/plain\r\nContent-Disposition: attachment\r\n\r\n" + c.originalMarker,
            "Content-Type: text/plain\r\nDKIM-Signature: test\r\n\r\n" + c.originalMarker,
            "Content-Type: multipart/signed\r\n\r\n" + c.originalMarker,
            "Content-Type: text/plain\r\nContent-Transfer-Encoding: base64\r\n\r\n" + c.originalMarker,
            "Content-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n" + c.originalMarker,
            "Content-Type: text/plain\r\nContent-Type: text/html\r\n\r\n" + c.originalMarker,
            "Content-Type: text/plain; charset=big5\r\n\r\n" + c.originalMarker,
            "Content-Type: text/plain\r\nX-Probe: bad\u{07}value\r\n\r\n" + c.originalMarker,
            "Content-Type: text/plain\r\nX-Probe: value\r\n bad\u{7F}fold\r\n\r\n" + c.originalMarker,
            "Content-Type: text/plain\r\n\r\n中文" + c.originalMarker
        ]
        for raw in cases { XCTAssertNil(c.replacement(in: Data(raw.utf8)), raw) }
    }

    func testMailKitCarrierPreservesUnsignedBytesButDoesNotProveHostUse() {
        let bytes = Data("Subject: synthetic\r\n\r\nprobe".utf8)
        let encoded = MEEncodedOutgoingMessage(rawData: bytes, isSigned: false, isEncrypted: false)
        let result = MEMessageEncodingResult(encodedMessage: encoded, signingError: nil, encryptionError: nil)
        XCTAssertEqual(result.encodedMessage?.rawData, bytes)
        XCTAssertEqual(result.encodedMessage?.isSigned, false)
        XCTAssertEqual(result.encodedMessage?.isEncrypted, false)
    }
}
