import XCTest
import SwiftMail
@testable import CheAppleMailMCP

/// #742 — how SwiftMail's report of one submission maps to the three outcomes.
/// The table of Requirement: A submission has one of three outcomes, at the
/// transport boundary. Built from SwiftMail's public initializers: no network.
final class SubmitOutcomeClassificationTests: XCTestCase {

    private func failure(_ acceptance: SMTPSendError.Acceptance, _ reason: SMTPSendError.Reason,
                         phase: SMTPSendError.Phase = .content) -> SubmitOutcome {
        SwiftMailSession.classify(.failure(SMTPSendError(phase: phase, acceptance: acceptance, reason: reason)))
    }

    /// Requirement: Connections are encrypted before the password is sent.
    func testEveryPortGetsTLS_implicitOn465And993_requiredStartTLSOtherwise() {
        XCTAssertEqual(SwiftMailSession.transportSecurity(forPort: 993), .implicitTLS)
        XCTAssertEqual(SwiftMailSession.transportSecurity(forPort: 465), .implicitTLS)
        for port in [587, 143, 25, 2525] {
            XCTAssertEqual(SwiftMailSession.transportSecurity(forPort: port), .startTLS, "\(port)")
        }
    }

    func testAFinal2xxIsAccepted_withTheReply() {
        let outcome = SwiftMailSession.classify(.success(SMTPSendResult(response: SMTPResponse(code: 250, message: "2.0.0 OK queued"))))
        XCTAssertEqual(outcome, .accepted(reply: "250 2.0.0 OK queued"))
    }

    func testProvablyNotAcceptedCasesAreNotSent() {
        XCTAssertEqual(failure(.notAccepted, .reply(SMTPResponse(code: 550, message: "no such user")), phase: .rcptTo),
                       .notAccepted(reply: "550 no such user"))
        XCTAssertEqual(failure(.rejectedPermanently, .reply(SMTPResponse(code: 552, message: "too big"))),
                       .notAccepted(reply: "552 too big"))
        XCTAssertEqual(failure(.rejectedTransiently, .reply(SMTPResponse(code: 451, message: "try later"))),
                       .notAccepted(reply: "451 try later"))
        XCTAssertEqual(failure(.notAccepted, .connectionLost, phase: .mailFrom), .notAccepted(reply: nil))
        XCTAssertEqual(SwiftMailSession.classify(.failure(SMTPError.authenticationFailed("bad"))), .notAccepted(reply: nil))
        XCTAssertEqual(SwiftMailSession.classify(.failure(SMTPError.connectionFailed("refused"))), .notAccepted(reply: nil))
    }

    func testAmbiguousAndUnrecognisedCasesAreUnknown() {
        for reason in [SMTPSendError.Reason.connectionLost, .timedOut, .cancelled, .transport("tls")] {
            guard case .unknown = failure(.ambiguous, reason) else { return XCTFail("\(reason) should be unknown") }
        }
        struct Odd: Error {}
        guard case .unknown = SwiftMailSession.classify(.failure(Odd())) else { return XCTFail("an unrecognised error should be unknown") }
        guard case .unknown = SwiftMailSession.classify(.failure(CancellationError())) else {
            return XCTFail("a cancellation outside SwiftMail's contract should be unknown")
        }
    }

    func testThePasswordAndItsLoginEncodingsAreRedacted() {
        let password = "abcd-efgh-ijkl-mnop"
        let plain = Data("\u{0}me@x.example\u{0}\(password)".utf8).base64EncodedString()
        let login = Data(password.utf8).base64EncodedString()
        let text = "535 auth failed for \(password); AUTH PLAIN \(plain); AUTH LOGIN \(login)"
        let out = SwiftMailSession.redact(text, password: password, username: "me@x.example")
        XCTAssertFalse(out.contains(password) || out.contains(plain) || out.contains(login), out)
        XCTAssertTrue(out.contains("535 auth failed"))
    }

    /// A To, Cc or Bcc field the envelope left empty may hold text the server
    /// could not parse: the draft is then refused.
    func testAHeaderFieldWithNoEnvelopeAddressIsNotCovered() {
        XCTAssertTrue(SwiftMailSession.envelopeCoversHeader(fieldNames: ["from", "to"], to: 1, cc: 0, bcc: 0))
        XCTAssertFalse(SwiftMailSession.envelopeCoversHeader(fieldNames: ["to", "cc"], to: 1, cc: 0, bcc: 0))
        XCTAssertFalse(SwiftMailSession.envelopeCoversHeader(fieldNames: ["to", "bcc"], to: 1, cc: 0, bcc: 0))
        XCTAssertTrue(SwiftMailSession.envelopeCoversHeader(fieldNames: ["to", "cc"], to: 1, cc: 2, bcc: 0))
    }
}
