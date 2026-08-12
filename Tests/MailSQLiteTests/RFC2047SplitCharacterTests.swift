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

/// #352 verify round (cross-model) — three P1 regressions the first version of
/// the fix introduced, all reproduced against that version before it changed.
///
/// They share one root: the run was treated as an all-or-nothing unit whose
/// boundaries were decided too early. Aliases of one charset were treated as
/// two; a single undecodable word discarded its run-mates' successful decodes;
/// and the whitespace between words was dropped before it was known whether
/// the next word would even join the run.
final class RFC2047RunBoundaryTests: XCTestCase {

    /// `stringEncoding(for:)` already maps `utf-8` and `utf8` to the same
    /// encoding — so the run must break on the RESOLVED encoding, not on the
    /// label. Before: the two words never joined and both came back raw.
    func testCharsetAliasesShareARun() {
        XCTAssertEqual(RFC822Parser.decodeRFC2047("=?utf-8?B?5g==?= =?utf8?B?l6U=?="), "日")
    }

    /// Before: BOTH words came back raw, losing an `A` the pre-#352 decoder
    /// returned — which is exactly the "fallback is byte-identical" claim
    /// being false. A run that fails as a unit now replays per word.
    func testOneUndecodableWordDoesNotPoisonItsRunMates() {
        XCTAssertEqual(RFC822Parser.decodeRFC2047("=?utf-8?B?QQ==?= =?utf-8?B?gA==?="),
                       "A=?utf-8?B?gA==?=")
    }

    /// Before: the separator was dropped the moment the first word decoded,
    /// so a following transport failure silently deleted it from a subject or
    /// an attachment filename.
    func testSeparatorSurvivesATransportFailureAfterASuccessfulWord() {
        XCTAssertEqual(RFC822Parser.decodeRFC2047("=?utf-8?B?gA==?= =?utf-8?B?%%%?="),
                       "=?utf-8?B?gA==?= =?utf-8?B?%%%?=")
    }

    /// The claim, pinned properly this time: wherever a run does NOT decode as
    /// a unit, the output must equal the pre-#352 algorithm byte for byte. The
    /// reference below IS that algorithm, transcribed from the code this fix
    /// replaced, so the comparison cannot drift into agreeing with the new one.
    func testFallbackIsByteIdenticalToThePreFixAlgorithm() {
        let cases = [
            "=?utf-8?B?QQ==?= =?utf-8?B?gA==?=",
            "=?utf-8?B?gA==?= =?utf-8?B?%%%?=",
            "=?utf-8?B?gA==?= =?utf-8?B?gQ==?=",
            "=?utf-8?B?QQ==?= plain =?utf-8?B?Qg==?=",
            "Re: =?utf-8?B?gA==?= (fwd)",
            "=?utf-8?B?%%%?=",
            "report=?bogus.pdf",
            "=?utf-8?Q?caf=E9?=",
            "no encoded words here",
            "",
        ]
        for input in cases {
            XCTAssertEqual(RFC822Parser.decodeRFC2047(input), Self.preFixReference(input),
                           "diverged from the pre-#352 behaviour on: \(input)")
        }
    }

    /// Verbatim transcription of the decoder as it stood before #352: decode
    /// each word to a String independently, drop LWS only after a success.
    private static func preFixReference(_ value: String) -> String {
        var result = ""
        var remaining = value[value.startIndex...]
        var lastWasEncodedWord = false
        while !remaining.isEmpty {
            guard let startRange = remaining.range(of: "=?", options: .literal) else {
                result += remaining; break
            }
            let prefix = remaining[remaining.startIndex..<startRange.lowerBound]
            if lastWasEncodedWord && prefix.unicodeScalars.allSatisfy({
                $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
                // dropped
            } else {
                result += prefix
            }
            let afterEq = remaining[startRange.upperBound...]
            guard let parsed = RFC822Parser.parseEncodedWordForTesting(afterEq) else {
                result += "=?"
                remaining = remaining[startRange.upperBound...]
                lastWasEncodedWord = false
                continue
            }
            var decoded: String?
            let enc = RFC822Parser.stringEncoding(for: parsed.charset)
            if parsed.encoding == "B" {
                if let d = Data(base64Encoded: parsed.text) { decoded = String(data: d, encoding: enc) }
            } else if parsed.encoding == "Q" {
                if let d = RFC822Parser.decodeQuotedPrintableBytes(
                    parsed.text.replacingOccurrences(of: "_", with: " ")) {
                    decoded = String(data: d, encoding: enc)
                }
            }
            if let decoded = decoded {
                result += decoded; lastWasEncodedWord = true
            } else {
                result += String(remaining[startRange.lowerBound..<parsed.endIndex])
                lastWasEncodedWord = false
            }
            remaining = remaining[parsed.endIndex...]
        }
        return result
    }
}
