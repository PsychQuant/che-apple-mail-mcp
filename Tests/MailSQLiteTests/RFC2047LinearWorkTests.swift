import XCTest
@testable import MailSQLite

/// #720 — `decodeRFC2047` must do work linear in the length of the value, and
/// its output must not change.
///
/// Two kinds of test:
///  - differential: the algorithm as it stood before #720 is kept below as a
///    test-only reference (a verbatim copy, not a call into the parser) and the
///    parser must agree with it on fixtures, on every short string over a small
///    alphabet, and on seeded pseudo-random strings built from encoded-word
///    fragments;
///  - work count: `RFC822Parser.terminatorSearchWorkProbe` reports how many
///    characters the searches for `?=` examined; the tests assert that count
///    grows at most linearly when the value is doubled and quadrupled. No clock.
final class RFC2047LinearWorkTests: XCTestCase {

    override func tearDown() {
        RFC822Parser.terminatorSearchWorkProbe = nil
        super.tearDown()
    }

    // MARK: - Differential

    private func assertSame(_ input: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = RFC2047Reference.decode(input)
        let actual = RFC822Parser.decodeRFC2047(input)
        if expected != actual {
            XCTFail("decodeRFC2047 diverged from the pre-#720 algorithm on \(String(reflecting: input)): "
                    + "expected \(String(reflecting: expected)), got \(String(reflecting: actual))",
                    file: file, line: line)
        }
    }

    /// Values taken from the existing RFC 2047 / header tests plus the shapes
    /// the decoder has special handling for.
    private static let fixtures: [String] = [
        "=?us-ascii?Q?caf=E9?=", "=?us-ascii?B?5pel?=", "=?us-ascii?Q?plain?=",
        "=?utf-8?B?5pel5pys?=", "=?utf-8?B?5pel?= =?utf-8?B?5pys?=",
        "=?utf-8?B?5pel?= =?iso-8859-1?Q?caf=E9?=", "Re: =?utf-8?B?5pel5pys?= (fwd)",
        "=?utf-8?B?gA==?= =?utf-8?B?gQ==?=", "report=?bogus.pdf",
        "=?utf-8?B?5g==?= =?utf8?B?l6U=?=", "=?utf-8?B?QQ==?= =?utf-8?B?gA==?=",
        "=?utf-8?B?gA==?= =?utf-8?B?%%%?=", "=?utf-8?B?gA==?= =?utf-8?B?gQ==?=",
        "=?utf-8?B?QQ==?= plain =?utf-8?B?Qg==?=", "Re: =?utf-8?B?gA==?= (fwd)",
        "=?utf-8?B?%%%?=", "=?utf-8?Q?caf=E9?=", "no encoded words here", "",
        "=?utf-8?Q?a=+5b?=", "=?utf-8?Q?a=-0b?=", "=?utf-8?Q?caf=c3=a9?=",
        "=?utf-8?B?YWJj?=\n=?utf-8?B?ZGVm?=", "=?utf-8?B?YWJj?=\r=?utf-8?B?ZGVm?=",
        "=?utf-8?B?YWJj?=\r\n=?utf-8?B?ZGVm?=", "=?utf-8?B?YWJj?= =?utf-8?B?ZGVm?=",
        "=?utf-8?B?YWJj?=\t=?utf-8?B?ZGVm?=",
        "=?utf-8?B?44CQ6K2Y5Yil6K2J55Sz6KuLLeWFvOS7u+aVmeW4q+OAkeij?= "
            + "=?utf-8?B?veWNoeWujOaIkCAtIOezu+e1seiHquWLlemAmuefpeS/oeS7tuiri+WL?= "
            + "=?utf-8?B?v+WbnuS/oSEh?=",
        "=?utf-8?Q?=E6=97=A5=E6?= =?utf-8?Q?=9C=AC?=",
        "=?utf-8?Q?a_b?=", "=?UTF-8?q?x?=", "=?utf-8?b?QUJD?=", "=?x?B?QUJD", "=?x?B?QUJD =?x?B?QUJD?=",
        "=?a?B?x =?a?B?x", "=?a?B?x?= =?a?B?x", "=?a?B?x?==?a?B?x?=", "=?=?=?", "?=?=?=", "=?", "?=",
        "=?utf-8?B?5pel?=\u{301}", "=?utf-8?B?5pel?\u{301}=", "é=?utf-8?B?5pel?=é",
        "=?euc-jp?B?pKQ=?= =?iso-2022-jp?B?GyRCJCQbKEI=?=", "=?big5?B?pKQ=?= =?nosuch?B?QUJD?=",
    ]

    func testFixturesMatchTheReference() {
        for input in Self.fixtures { assertSame(input) }
    }

    /// Every string up to length 5 over characters the tokenizer treats specially.
    func testEveryShortStringOverASmallAlphabetMatchesTheReference() {
        let alphabet: [Character] = ["=", "?", "B", "Q", "q", "_", " ", "\t", "\r\n", "\n", "a", "Z", "é"]
        var count = 0
        func extend(_ prefix: String, _ remaining: Int) {
            assertSame(prefix)
            count += 1
            if remaining == 0 { return }
            for c in alphabet { extend(prefix + String(c), remaining - 1) }
        }
        extend("", 5)
        XCTAssertGreaterThan(count, 100_000)
    }

    /// Every string up to length 6 over characters that change how Characters are formed around a
    /// `?`: a combining mark (U+0301) joins the character before it, a prepended concatenation mark
    /// (U+0600) joins the character after it.
    func testEveryShortStringWithJoiningMarksMatchesTheReference() {
        let alphabet: [String] = ["=", "?", "Q", "B", "\u{0301}", "\u{0600}", "a", " "]
        var count = 0
        func extend(_ prefix: String, _ remaining: Int) {
            assertSame(prefix)
            count += 1
            if remaining == 0 { return }
            for c in alphabet { extend(prefix + c, remaining - 1) }
        }
        extend("", 6)
        XCTAssertGreaterThan(count, 250_000)
    }

    /// Every sequence of up to 5 encoded-word pieces.
    func testEverySequenceOfEncodedWordPiecesMatchesTheReference() {
        let pieces = ["=?utf-8?B?", "=?utf-8?Q?", "=?x?B?", "=?utf8?q?", "?=", " ", "\r\n ", "QQ==", "gA==", "=E6", "a_b", "é", "="]
        var count = 0
        func extend(_ prefix: String, _ remaining: Int) {
            assertSame(prefix)
            count += 1
            if remaining == 0 { return }
            for p in pieces { extend(prefix + p, remaining - 1) }
        }
        extend("", 5)
        XCTAssertGreaterThan(count, 100_000)
    }

    /// Seeded pseudo-random values built from encoded-word fragments.
    func testSeededRandomValuesMatchTheReference() {
        var rng = SplitMix64(seed: 0x720_0720)
        let words = [
            "=?utf-8?B?5pel5pys?=", "=?utf-8?B?5pel?=", "=?utf-8?B?5pys?=", "=?UTF8?Q?=E6=97=A5?=", "=?utf-8?Q?=E6=9C=AC?=",
            "=?iso-8859-1?Q?caf=E9?=", "=?iso-8859-1?B?Y2Fm6Q==?=", "=?utf-8?B?gA==?=", "=?utf-8?B?%%%?=", "=?big5?B?pKQ=?=",
            "=?x?B?QUJD", "=?utf-8?Q?no end", "=?utf-8?B?", "=?utf-8?", "=?", "=?a?Z?x?=", "=?a?B?x?",
            "?=", "=", "?", "plain", "é", " ", "\t", "\r\n", "\r\n\t", "(", ")", "QQ==",
            "=?\u{0301}", "?\u{0301}", "\u{0600}?", "=?utf-8\u{0301}?Q?a?=", "=?utf-8?Q\u{0301}?a?=",
        ]
        for _ in 0..<6000 {
            var value = ""
            for _ in 0..<Int(rng.next() % 40) {
                value += words[Int(rng.next() % UInt64(words.count))]
                if rng.next() % 3 == 0 { value += [" ", "\t", "\r\n ", ""][Int(rng.next() % 4)] }
            }
            assertSame(value)
        }
    }

    // MARK: - Work count

    /// Characters the `?=` searches examined for one `decodeRFC2047` call.
    private func work(_ value: String) -> Int {
        var reported: Int?
        RFC822Parser.terminatorSearchWorkProbe = { reported = $0 }
        _ = RFC822Parser.decodeRFC2047(value)
        RFC822Parser.terminatorSearchWorkProbe = nil
        return reported ?? -1
    }

    /// Doubling and quadrupling the value must at most double and quadruple the
    /// work (plus a little slack for fixed prefixes and rounding).
    private func assertLinear(_ label: String, _ make: (Int) -> String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let n = 400
        let w1 = work(make(n)), w2 = work(make(2 * n)), w4 = work(make(4 * n))
        XCTAssertGreaterThanOrEqual(w1, 0, "\(label): the probe did not report", file: file, line: line)
        XCTAssertLessThanOrEqual(w2, w1 * 2 + w1 / 4 + 64,
                                 "\(label): work grew faster than linearly from n to 2n (\(w1) -> \(w2))",
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(w4, w1 * 4 + w1 / 2 + 64,
                                 "\(label): work grew faster than linearly from n to 4n (\(w1) -> \(w4))",
                                 file: file, line: line)
    }

    func testWorkIsLinearWhenNoWordHasATerminator() {
        assertLinear("no terminator") { String(repeating: "=?a?B?x ", count: $0) }
    }

    func testWorkIsLinearWithOneTerminatorAtTheVeryEnd() {
        assertLinear("one terminator at the end") { String(repeating: "=?a?B?x ", count: $0) + "?=" }
    }

    func testWorkIsLinearWhenATerminatorEndsOnlyTheFirstWord() {
        assertLinear("terminator then none") { "=?a?B?x?= " + String(repeating: "=?a?B?x ", count: $0) }
    }

    func testWorkIsLinearWhenEveryWordIsInvalidInAnotherWay() {
        assertLinear("bad base64, terminated") { String(repeating: "=?a?B?%%%?= ", count: $0) }
        assertLinear("unknown encoding letter") { String(repeating: "=?a?Z?x?= ", count: $0) }
        assertLinear("openers with no encoding part") { String(repeating: "=?a=?a=?a ", count: $0) }
    }

    func testWorkIsLinearForOneVeryLongValidWord() {
        assertLinear("one long word") { "=?utf-8?B?" + String(repeating: "QUJD", count: $0) + "?=" }
    }

    func testWorkIsLinearForManyValidWords() {
        assertLinear("many valid words") { String(repeating: "=?utf-8?B?QUJD?= ", count: $0) }
    }

    /// A `?` followed by a combining mark is one Character, so the search for the `?` that ends the
    /// charset does not see it, while the search for the opener (literal) does. Found by the
    /// cross-model review of #720.
    func testWorkIsLinearWhenTheOpenersQuestionMarkJoinsACombiningMark() {
        assertLinear("combining mark after every opener") { String(repeating: "=?\u{0301}", count: $0) }
        assertLinear("the same, then one charset end near the end") {
            String(repeating: "=?\u{0301}", count: $0) + "?Q?"
        }
        assertLinear("the same, then a whole word at the end") {
            String(repeating: "=?\u{0301}", count: $0) + "?Q?x?="
        }
    }

    func testWorkIsLinearForManyValidWordsFollowedByUnterminatedOnes() {
        assertLinear("valid then unterminated") {
            String(repeating: "=?utf-8?B?QUJD?= ", count: $0) + String(repeating: "=?utf-8?Q?ab ", count: $0)
        }
    }
}

/// SplitMix64: a fixed-seed generator so the random corpus is the same every run.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The decoder as it stood before #720, copied verbatim (only the names differ).
/// It is quadratic on purpose; keep generated values short.
enum RFC2047Reference {
    struct EncodedWord {
        let charset: String
        let encoding: String
        let text: String
        let endIndex: Substring.Index
    }

    static func decode(_ value: String) -> String {
        var result = ""
        var remaining = value[value.startIndex...]
        var lastWasEncodedWord = false

        // A run of adjacent encoded-words sharing one charset (#352).
        //
        // Decoding each word to a String on its own is wrong whenever a
        // multi-byte character straddles the word boundary: RFC 2047 §5 says an
        // encoded-word must hold an integral number of characters, and real
        // encoders break that by chunking the transport stream at a fixed
        // width. Measured on the reported subject: all three words had
        // well-formed base64 and none of their byte runs was valid UTF-8 alone.
        //
        // So the transport decode (base64 / QP) stays per word, and the CHARSET
        // conversion is applied once to the run's concatenated bytes.
        //
        // Three things the first version of this fix got wrong (#352 verify,
        // cross-model — all three reproduced before changing anything):
        //
        //  1. Runs were broken on the charset LABEL, so `utf-8` followed by
        //     `utf8` — aliases `RFC822Parser.stringEncoding(for:)` already maps to the same
        //     encoding — never joined. Runs now break on the RESOLVED encoding.
        //  2. One undecodable word poisoned the whole run: `A` + an invalid
        //     byte emitted BOTH words raw, losing an `A` the old code decoded.
        //     A run that fails as a whole now replays the old per-word
        //     algorithm, so the fallback really is what it claims to be.
        //  3. The whitespace between two words was dropped before knowing
        //     whether the second would join the run, so a transport failure
        //     silently deleted it. It is now held and committed only once the
        //     outcome is known.
        struct RunWord { let bytes: Data; let range: Range<String.Index> }
        var runEncoding: String.Encoding?
        var runWords: [RunWord] = []
        /// LWS after the last run word, not yet committed either way.
        var heldSeparator: Substring?

        /// Emit the open run. Returns whether the last thing emitted counts as
        /// a decoded encoded-word — which is what decides, per RFC 2047 §6.2,
        /// whether a following separator is dropped or kept.
        func flushRun() -> Bool {
            guard let encoding = runEncoding, !runWords.isEmpty else { return lastWasEncodedWord }
            defer { runEncoding = nil; runWords = [] }

            let joined = runWords.reduce(into: Data()) { $0.append($1.bytes) }
            if let decoded = ByteDecoding.string(from: joined, encoding: encoding) {
                result += decoded
                return true
            }

            // The run does not decode as a unit. Replay the pre-#352 per-word
            // behaviour so this path is byte-identical to what it replaced:
            // each word that decodes alone still decodes, each that does not is
            // emitted verbatim, and a separator survives exactly when the word
            // before it failed.
            var lastOK = false
            for (i, word) in runWords.enumerated() {
                if i > 0, !lastOK {
                    result += value[runWords[i - 1].range.upperBound..<word.range.lowerBound]
                }
                if let decoded = ByteDecoding.string(from: word.bytes, encoding: encoding) {
                    result += decoded
                    lastOK = true
                } else {
                    result += value[word.range]
                    lastOK = false
                }
            }
            return lastOK
        }

        /// Close the run and settle the held separator with it.
        func closeRun() {
            let decodedLast = flushRun()
            if let separator = heldSeparator {
                if !decodedLast { result += separator }
                heldSeparator = nil
            }
            lastWasEncodedWord = decodedLast
        }

        while !remaining.isEmpty {
            guard let startRange = remaining.range(of: "=?", options: .literal) else {
                closeRun()
                result += remaining
                break
            }

            let prefix = remaining[remaining.startIndex..<startRange.lowerBound]
            let prefixIsLWS = !prefix.isEmpty && prefix.unicodeScalars.allSatisfy {
                $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r"
            }
            if prefix.isEmpty {
                // nothing between the words
            } else if lastWasEncodedWord && prefixIsLWS {
                // RFC 2047 §6.2: LWS between two encoded-words is dropped — but
                // only if what follows really is one. Hold it until we know.
                // (Iterates unicodeScalars because Swift treats "\r\n" as a
                // single grapheme cluster that equals no individual literal.)
                heldSeparator = prefix
            } else {
                closeRun()
                result += prefix
            }

            let afterEq = remaining[startRange.upperBound...]
            guard let parsed = refParseEncodedWord(afterEq) else {
                closeRun()
                result += "=?"
                remaining = remaining[startRange.upperBound...]
                lastWasEncodedWord = false
                continue
            }

            // Transport decode only — the charset conversion belongs to the run.
            var bytes: Data?
            if parsed.encoding == "B" {
                bytes = Data(base64Encoded: parsed.text)
            } else if parsed.encoding == "Q" {
                // In encoded-words, `_` stands for space (not literal underscore).
                bytes = RFC822Parser.decodeQuotedPrintableBytes(
                    parsed.text.replacingOccurrences(of: "_", with: " "))
            }

            if let bytes = bytes {
                let encoding = RFC822Parser.stringEncoding(for: parsed.charset)
                // Compare the RESOLVED encoding, not the label: `utf-8` and
                // `utf8` are the same encoding and must share a run.
                if let open = runEncoding, open != encoding {
                    closeRun()
                }
                if runEncoding == nil { runEncoding = encoding }
                runWords.append(RunWord(
                    bytes: bytes,
                    range: startRange.lowerBound..<parsed.endIndex))
                // The separator now sits INSIDE the run's source span.
                heldSeparator = nil
                lastWasEncodedWord = true
            } else {
                // Cannot even transport-decode: this word joins no run.
                let decodedLast = flushRun()
                if let separator = heldSeparator {
                    if !decodedLast { result += separator }
                    heldSeparator = nil
                }
                result += String(remaining[startRange.lowerBound..<parsed.endIndex])
                lastWasEncodedWord = false
            }

            remaining = remaining[parsed.endIndex...]
        }

        closeRun()
        if let separator = heldSeparator { result += separator }
        return result
    }


    static func refParseEncodedWord(_ input: Substring) -> EncodedWord? {
        // Find charset: everything up to first ?
        guard let q1 = input.firstIndex(of: "?") else { return nil }
        let charset = String(input[input.startIndex..<q1])

        // Find encoding: single char after charset's ?
        let afterQ1 = input.index(after: q1)
        guard afterQ1 < input.endIndex else { return nil }
        let encoding = String(input[afterQ1]).uppercased()
        guard encoding == "B" || encoding == "Q" else { return nil }

        // After encoding there must be another ?
        let q2 = input.index(after: afterQ1)
        guard q2 < input.endIndex, input[q2] == "?" else { return nil }

        // Find the closing ?= — search from after the text-start ?
        let textStart = input.index(after: q2)
        let textRegion = input[textStart...]
        guard let endRange = textRegion.range(of: "?=", options: .literal) else { return nil }

        let text = String(textRegion[textRegion.startIndex..<endRange.lowerBound])

        return EncodedWord(
            charset: charset,
            encoding: encoding,
            text: text,
            endIndex: endRange.upperBound
        )
    }
}
