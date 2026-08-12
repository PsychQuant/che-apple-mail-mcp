import XCTest
@testable import MailSQLite

/// #352 — a multi-byte character split ACROSS adjacent encoded-words.
///
/// The reported symptom was that `batch_export_emails_markdown` wrote raw
/// `=?utf-8?B?…?=` into frozen frontmatter's `thread_key`. The issue read that
/// as "the decoder exists (#99/#123) but is not wired to this path". It is
/// wired — `RFC822Parser.parseHeaderBlock` decodes every non-`content-` header.
/// The decoder itself fails on this input.
///
/// Why: RFC 2047 §5 requires each encoded-word to encode an integral number of
/// characters, and encoders in the wild break that — they chunk the base64
/// stream at a fixed width, splitting a UTF-8 sequence across the boundary.
/// Measured on the reported subject: every segment's base64 is well-formed
/// (length % 4 == 0) and every segment's BYTES are invalid UTF-8 on their own
/// (`unexpected end of data` / `invalid start byte`). Only the concatenation
/// decodes. The old decoder converted each word to a `String` independently, so
/// all three conversions failed and all three words were re-emitted verbatim.
///
/// The fix accumulates raw BYTES across a run of adjacent same-charset
/// encoded-words and applies the charset conversion once, at the end of the
/// run — which is what Mail.app and Python's `email.header` do.
final class RFC2047SplitCharacterTests: XCTestCase {

    /// The exact value from #352 (a real message, 2026-08-07).
    private let splitSubject =
        "=?utf-8?B?44CQ6K2Y5Yil6K2J55Sz6KuLLeWFvOS7u+aVmeW4q+OAkeij?= "
        + "=?utf-8?B?veWNoeWujOaIkCAtIOezu+e1seiHquWLlemAmuefpeS/oeS7tuiri+WL?= "
        + "=?utf-8?B?v+WbnuS/oSEh?="
    private let expected = "【識別證申請-兼任教師】製卡完成 - 系統自動通知信件請勿回信!!"

    func testSplitMultibyteCharacterAcrossEncodedWords() {
        XCTAssertEqual(RFC822Parser.decodeRFC2047(splitSubject), expected,
            "adjacent same-charset encoded-words must have their BYTES concatenated "
            + "before the charset conversion; decoding each word to a String "
            + "independently fails when a character straddles the boundary")
    }

    /// The path the export actually takes: folded header → `parseHeaders`.
    func testSplitSubjectThroughFoldedHeaderParse() {
        let raw = "Subject: =?utf-8?B?44CQ6K2Y5Yil6K2J55Sz6KuLLeWFvOS7u+aVmeW4q+OAkeij?=\r\n"
            + " =?utf-8?B?veWNoeWujOaIkCAtIOezu+e1seiHquWLlemAmuefpeS/oeS7tuiri+WL?=\r\n"
            + " =?utf-8?B?v+WbnuS/oSEh?=\r\n"
            + "From: Someone <a@example.com>\r\n\r\nbody\r\n"
        let headers = RFC822Parser.parseHeaders(from: Data(raw.utf8))
        XCTAssertEqual(headers["subject"], expected)
    }

    /// Quoted-printable has the same split hazard; cover it too so the fix is
    /// not silently B-only.
    func testSplitMultibyteCharacterAcrossQuotedPrintableWords() {
        // "日本" = E6 97 A5 E6 9C AC, split mid-character between the words.
        let value = "=?utf-8?Q?=E6=97=A5=E6?= =?utf-8?Q?=9C=AC?="
        XCTAssertEqual(RFC822Parser.decodeRFC2047(value), "日本")
    }

    // MARK: - The behaviour that must NOT change

    func testSingleEncodedWordStillDecodes() {
        XCTAssertEqual(RFC822Parser.decodeRFC2047("=?utf-8?B?5pel5pys?="), "日本")
    }

    func testAdjacentWordsThatEachDecodeAloneAreStillJoinedWithoutSeparator() {
        // RFC 2047 §6.2: LWS between two encoded-words is dropped.
        XCTAssertEqual(RFC822Parser.decodeRFC2047("=?utf-8?B?5pel?= =?utf-8?B?5pys?="), "日本")
    }

    func testDifferentCharsetsAreDecodedSeparately() {
        // A run must not span a charset change: latin1 bytes must not be
        // appended to a utf-8 run.
        let value = "=?utf-8?B?5pel?= =?iso-8859-1?Q?caf=E9?="
        XCTAssertEqual(RFC822Parser.decodeRFC2047(value), "日café")
    }

    func testSurroundingLiteralTextIsPreserved() {
        let value = "Re: =?utf-8?B?5pel5pys?= (fwd)"
        XCTAssertEqual(RFC822Parser.decodeRFC2047(value), "Re: 日本 (fwd)")
    }

    /// A run whose concatenated bytes STILL do not decode must fall back to the
    /// verbatim source — including the separators between the words, exactly as
    /// before the fix. Truncating or reordering the fallback would turn an
    /// undecodable subject into a corrupted one.
    func testUndecodableRunFallsBackToVerbatimSourceIncludingSeparators() {
        // Lone continuation bytes: invalid UTF-8 individually AND concatenated.
        let value = "=?utf-8?B?gA==?= =?utf-8?B?gQ==?="
        XCTAssertEqual(RFC822Parser.decodeRFC2047(value), value)
    }

    func testMalformedEncodedWordSurvivesVerbatim() {
        // Not a complete encoded-word — must pass through untouched (#115).
        XCTAssertEqual(RFC822Parser.decodeRFC2047("report=?bogus.pdf"), "report=?bogus.pdf")
    }
}
