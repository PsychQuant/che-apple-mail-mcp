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

    func testAPasswordInServerTextIsDetectedInEveryLoginForm() {
        let pw = "abcd-efgh-ijkl-mnop"
        XCTAssertTrue(SwiftMailSession.containsPassword("<\(pw)@x>", password: pw, username: "me@x.example"))
        let b64 = Data(pw.utf8).base64EncodedString()
        XCTAssertTrue(SwiftMailSession.containsPassword("Re: \(b64)", password: pw, username: "me@x.example"))
        XCTAssertFalse(SwiftMailSession.containsPassword("<d1@x>", password: pw, username: "me@x.example"))
    }

    func testTheSearchTermIsTheMessageIDWithoutBrackets() {
        XCTAssertEqual(SwiftMailSession.searchTerm(for: "<a.b@x.example>"), "a.b@x.example")
        XCTAssertEqual(SwiftMailSession.searchTerm(for: "a.b@x.example"), "a.b@x.example")
    }

    func testThePasswordIsRedactedBeforeTheTextIsCut_andInItsQuotedAndAuthzidForms() {
        let password = #"p"a\ss-word-0123"#
        // The password straddles character 300: cut first, its prefix would survive.
        let text = String(repeating: "x", count: 290) + password
        let out = SwiftMailSession.clip(SwiftMailSession.redact(text, password: password, username: "me@x.example"))
        XCTAssertFalse(out.contains(#"p"a\ss"#), out)
        let quoted = #"LOGIN me@x.example "p\"a\\ss-word-0123""#
        XCTAssertFalse(SwiftMailSession.redact(quoted, password: password, username: "me@x.example").contains("ss-word"))
        let authz = Data("me@x.example\u{0}me@x.example\u{0}\(password)".utf8).base64EncodedString()
        XCTAssertFalse(SwiftMailSession.redact("AUTH PLAIN \(authz)", password: password, username: "me@x.example").contains(authz))
    }

    /// A field that names more addresses than the envelope reports, or a field
    /// given twice, may hold text the server could not parse: refused.
    func testTheHeaderAddressFieldsMustAgreeWithTheEnvelope() throws {
        func agree(_ header: String, from: Int = 1, to: Int = 1, cc: Int = 0, bcc: Int = 0) throws -> (sender: Bool, recipients: Bool) {
            let fields = try BccRemoval.fields(in: Data((header + "\r\n").utf8))
            return SwiftMailSession.addressFieldsAgree(fields: fields, from: from, to: to, cc: cc, bcc: bcc)
        }
        let ok = try agree("From: Me <me@x.example>\r\nTo: a@x.example\r\n")
        XCTAssertTrue(ok.sender && ok.recipients)
        XCTAssertFalse(try agree("From: me@x.example\r\nTo: a@x.example, b@@x\r\n").recipients, "one address dropped")
        XCTAssertFalse(try agree("From: me@x.example\r\nTo: a@x.example, junk\r\n").recipients,
                       "a stray word the envelope left out")
        XCTAssertFalse(try agree("From: me@x.example\r\nTo: a@x.example\r\nTo: b@x.example\r\n").recipients, "To twice")
        XCTAssertFalse(try agree("From: me@x.example\r\nTo: a@x.example\r\nCc: junk\r\n").recipients, "a Cc the envelope left empty")
        XCTAssertTrue(try agree("From: me@x.example\r\nTo: undisclosed-recipients:;\r\nBcc: a@x.example\r\n", to: 0, bcc: 1).recipients,
                      "an empty group is a valid To")
        XCTAssertFalse(try agree("To: a@x.example\r\n", from: 0).sender, "no From")
        XCTAssertFalse(try agree("From: me@x.example\r\nFrom: you@x.example\r\nTo: a@x.example\r\n").sender, "From twice")
        XCTAssertTrue(try agree(#"From: "a@b" (c@d) <me@x.example>"# + "\r\nTo: a@x.example\r\n").sender,
                      "an @ in a quoted name or a comment is not an address")
    }
}
