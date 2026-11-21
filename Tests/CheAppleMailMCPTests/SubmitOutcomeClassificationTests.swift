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
}
