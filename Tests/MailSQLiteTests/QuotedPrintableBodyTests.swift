import XCTest
@testable import MailSQLite

/// #339 — `get_email(format: "text")` and `batch_export_emails_markdown`
/// returned raw quoted-printable for `text/plain`, while the same message's
/// `html_body` decoded fine. 19 of 28 messages in one archive run were
/// unreadable, with every gate green.
///
/// The issue attributed this to the parser not decoding QP. Reproducing it
/// against the reported message (`289314.emlx`, Klaviyo) found **two**
/// separate defects, and neither is "QP is not decoded":
///
///  1. `=` + CRLF soft line breaks were never collapsed. Swift treats `"\r\n"`
///     as ONE extended grapheme cluster, so `char == "\r"` and `char == "\n"`
///     are BOTH false for it — the same trap `decodeRFC2047` documents for its
///     LWS scan (#125). LF-only messages worked, CRLF ones did not, which is
///     the majority of real wire traffic.
///  2. The reported part declares `Content-Transfer-Encoding: 7bit` with
///     `charset=US-ASCII` while its body is plainly QP-encoded UTF-8. The
///     parser obeyed the header and passed it through — correctly, per the
///     header, and uselessly, per the content. The sibling `text/html` part in
///     the SAME message declares `quoted-printable` properly, which is exactly
///     why one decoded and the other did not.
final class QuotedPrintableBodyTests: XCTestCase {

    private func body(_ lines: [String], crlf: Bool = true) -> (Data, [String: String]) {
        let sep = crlf ? "\r\n" : "\n"
        let msg = lines.joined(separator: sep)
        let data = Data(msg.utf8)
        let headers = RFC822Parser.parseHeaders(from: data)
        let split = RFC822Parser.headerBodySplitOffset(in: data)!
        return (Data(data[split...]), headers)
    }

    // MARK: - Defect 1: CRLF soft line breaks

    func testSoftLineBreakIsCollapsedWithCRLF() {
        let (b, h) = body([
            "Content-Type: text/plain; charset=\"utf-8\"",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            "soft=", "break", ""
        ])
        XCTAssertEqual(MIMEParser.parseBody(b, headers: h).textBody?
            .trimmingCharacters(in: .whitespacesAndNewlines), "softbreak",
            "`=` at end of line is a soft break (RFC 2045 §6.7) and must vanish, "
            + "joining the two halves — Swift's \"\\r\\n\" grapheme cluster equals "
            + "neither \"\\r\" nor \"\\n\", so the old check never matched")
    }

    func testSoftLineBreakStillCollapsedWithBareLF() {
        let (b, h) = body([
            "Content-Type: text/plain; charset=\"utf-8\"",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            "soft=", "break", ""
        ], crlf: false)
        XCTAssertEqual(MIMEParser.parseBody(b, headers: h).textBody?
            .trimmingCharacters(in: .whitespacesAndNewlines), "softbreak")
    }

    // MARK: - Defect 2: a part that lies about its encoding

    func testMislabelled7bitPartThatIsActuallyQPIsRecovered() {
        // Byte-for-byte the shape of the reported message: 7bit + US-ASCII
        // declared, QP-encoded UTF-8 delivered.
        let (b, h) = body([
            "Content-Type: multipart/alternative; boundary=\"B\"",
            "",
            "--B",
            "Content-Transfer-Encoding: 7bit",
            "Content-Type: text/plain; charset=US-ASCII",
            "",
            "=E6=82=A8=E5=A5=BD=EF=BC=9A",
            "",
            "--B",
            "Content-Type: text/html; charset=\"utf-8\"",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            "<p>=E6=82=A8=E5=A5=BD</p>",
            "",
            "--B--", ""
        ])
        let parsed = MIMEParser.parseBody(b, headers: h)
        XCTAssertEqual(parsed.textBody?.trimmingCharacters(in: .whitespacesAndNewlines), "您好：",
            "the part lies about its encoding; recovering it is the whole point of #339")
        XCTAssertEqual(parsed.htmlBody?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "<p>您好</p>", "the correctly-labelled sibling must be unaffected")
    }

    // MARK: - The salvage must not corrupt honest 7bit text

    func testGenuine7bitAsciiIsLeftAlone() {
        // A document that TALKS about QP. Decoding "=41" would silently rewrite
        // it to "A". The salvage only fires when the decode recovers non-ASCII,
        // so pure-ASCII content like this is never touched.
        let (b, h) = body([
            "Content-Type: text/plain; charset=us-ascii",
            "Content-Transfer-Encoding: 7bit",
            "",
            "In quoted-printable, =41 encodes the letter A and =3D encodes itself.",
            ""
        ])
        XCTAssertEqual(MIMEParser.parseBody(b, headers: h).textBody?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            "In quoted-printable, =41 encodes the letter A and =3D encodes itself.")
    }

    func testGenuine7bitTextWithNoEqualsSignsIsLeftAlone() {
        let (b, h) = body([
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 7bit",
            "",
            "Plain sentence, nothing encoded.", ""
        ])
        XCTAssertEqual(MIMEParser.parseBody(b, headers: h).textBody?
            .trimmingCharacters(in: .whitespacesAndNewlines), "Plain sentence, nothing encoded.")
    }

    func testMislabelledPartWhoseDecodeIsNotValidTextIsLeftAlone() {
        // `=E7` alone decodes to a lone continuation byte — not valid UTF-8.
        // The salvage self-validates, so this stays verbatim rather than
        // becoming replacement characters.
        let (b, h) = body([
            "Content-Type: text/plain; charset=us-ascii",
            "Content-Transfer-Encoding: 7bit",
            "",
            "stray =E7 escape", ""
        ])
        XCTAssertEqual(MIMEParser.parseBody(b, headers: h).textBody?
            .trimmingCharacters(in: .whitespacesAndNewlines), "stray =E7 escape")
    }

    func testDeclaredBase64PartIsNotSecondGuessed() {
        // Already-decoded content that happens to contain "=XX" must not be
        // re-decoded — the salvage applies only to undecoded 7bit/8bit parts.
        let payload = Data("total =3D 5".utf8).base64EncodedString()
        let (b, h) = body([
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            payload, ""
        ])
        XCTAssertEqual(MIMEParser.parseBody(b, headers: h).textBody?
            .trimmingCharacters(in: .whitespacesAndNewlines), "total =3D 5")
    }
}
