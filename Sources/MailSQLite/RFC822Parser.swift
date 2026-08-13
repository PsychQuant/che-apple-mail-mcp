import Foundation

/// Parser for RFC 822 email headers.
/// Handles header folding (continuation lines) and RFC 2047 encoded-word decoding.
public enum RFC822Parser {

    /// Parse raw message data and extract headers as a dictionary.
    /// Header names are lowercased. Values are decoded (folding removed, RFC 2047 decoded).
    ///
    /// - Parameter data: Raw RFC 822 message data.
    /// - Returns: Dictionary mapping lowercase header names to decoded values.
    public static func parseHeaders(from data: Data) -> [String: String] {
        // findDoubleCRLF returns an absolute Data index (slice-safe per #72).
        if let splitIdx = findDoubleCRLF(in: data) {
            return parseHeaderBlock(data[data.startIndex..<splitIdx])
        }
        // No body separator found — treat entire data as headers.
        return parseHeaderBlock(data)
    }

    /// Find the absolute Data index where the body begins (after `\r\n\r\n`
    /// or `\n\n`). Returns an index suitable for `data[returnedIndex...]`,
    /// or nil if no separator is found.
    ///
    /// **Slice safety (#72)**: `data` may be a slice with non-zero
    /// `startIndex`. The returned value is an absolute Data index relative
    /// to the original buffer — callers can write `data[offset...]` and
    /// `data.endIndex` directly without manual `data.startIndex` arithmetic.
    public static func headerBodySplitOffset(in data: Data) -> Int? {
        // Look for \r\n\r\n
        if data.count >= 4 {
            for i in data.startIndex..<(data.endIndex - 3) {
                if data[i] == 0x0D && data[i + 1] == 0x0A
                    && data[i + 2] == 0x0D && data[i + 3] == 0x0A {
                    return i + 4
                }
            }
        }
        // Fallback: look for \n\n (some messages use bare LF)
        if data.count >= 2 {
            for i in data.startIndex..<(data.endIndex - 1) {
                if data[i] == 0x0A && data[i + 1] == 0x0A {
                    return i + 2
                }
            }
        }
        return nil
    }

    // MARK: - Private

    /// Find the absolute Data index of the `\r\n\r\n` (or fallback `\n\n`)
    /// separator. Returns the index of the **first** byte of the separator,
    /// suitable for `data[..<returnedIndex]` to slice the headers.
    ///
    /// Honors `data.startIndex` (slice safety, #72).
    private static func findDoubleCRLF(in data: Data) -> Int? {
        if data.count >= 4 {
            for i in data.startIndex..<(data.endIndex - 3) {
                if data[i] == 0x0D && data[i + 1] == 0x0A
                    && data[i + 2] == 0x0D && data[i + 3] == 0x0A {
                    return i
                }
            }
        }
        if data.count >= 2 {
            for i in data.startIndex..<(data.endIndex - 1) {
                if data[i] == 0x0A && data[i + 1] == 0x0A {
                    return i
                }
            }
        }
        return nil
    }

    private static func parseHeaderBlock(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii) else {
            return [:]
        }

        // Unfold continuation lines: replace \r\n + whitespace with single space
        var unfolded = text
            .replacingOccurrences(of: "\r\n ", with: " ")
            .replacingOccurrences(of: "\r\n\t", with: " ")
            .replacingOccurrences(of: "\n ", with: " ")
            .replacingOccurrences(of: "\n\t", with: " ")

        var headers: [String: String] = [:]
        let lines = unfolded.components(separatedBy: .newlines)
        for line in lines {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colonIdx]).lowercased().trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            // Structured MIME headers (Content-Type, Content-Disposition, …)
            // are NOT RFC 2047-decoded at the raw-header level. Per RFC 2047
            // §5 an encoded-word may not appear in a structured field body;
            // the only place a filename encoded-word legitimately surfaces is
            // inside a `filename`/`name` parameter, which MIMEParser decodes
            // per-parameter (`resolveFilename` → `decodeRFC2047IfApplicable`).
            // A header-level scan decodes encoded-words fully contained in one
            // RFC 2231 continuation segment but mangles ones whose `=?` opener
            // straddles the `"; filename*N="` boundary — leaving a
            // half-decoded value the per-parameter decoder can no longer
            // recognise, so the attachment is silently dropped (#115).
            headers[name] = name.hasPrefix("content-") ? value : decodeRFC2047(value)
        }
        return headers
    }

    // MARK: - RFC 2047 Encoded-Word Decoding

    /// Decode RFC 2047 encoded-words in a header value.
    /// Format: =?charset?encoding?encoded_text?=
    /// encoding: B = base64, Q = quoted-printable
    static func decodeRFC2047(_ value: String) -> String {
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
        //     `utf8` — aliases `stringEncoding(for:)` already maps to the same
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
            if let decoded = String(data: joined, encoding: encoding) {
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
                if let decoded = String(data: word.bytes, encoding: encoding) {
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
            guard let parsed = parseEncodedWord(afterEq) else {
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
                bytes = decodeQuotedPrintableBytes(
                    parsed.text.replacingOccurrences(of: "_", with: " "))
            }

            if let bytes = bytes {
                let encoding = stringEncoding(for: parsed.charset)
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

    /// #352 verify: lets the differential test drive the pre-fix reference
    /// algorithm through the same tokenizer, so any divergence it reports is a
    /// real behavioural difference and not a second parser disagreeing.
    static func parseEncodedWordForTesting(_ input: Substring) -> (charset: String, encoding: String, text: String, endIndex: Substring.Index)? {
        guard let w = parseEncodedWord(input) else { return nil }
        return (w.charset, w.encoding, w.text, w.endIndex)
    }

    private struct EncodedWord {
        let charset: String
        let encoding: String
        let text: String
        let endIndex: Substring.Index
    }

    /// Parse an encoded word after the initial "=?" has been consumed.
    /// Input starts right after "=?" — e.g., "utf-8?Q?=E9=84=AD?= rest"
    private static func parseEncodedWord(_ input: Substring) -> EncodedWord? {
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

    // `decodeBase64` / `decodeQuotedPrintableWord` (per-word transport + charset
    // in one step) were removed by #352: converting each word to a String is
    // precisely the bug. The transport decode is now inline in `decodeRFC2047`
    // and the charset conversion happens once per run.

    static func decodeQuotedPrintableBytes(_ text: String) -> Data? {
        var data = Data()
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "=" {
                let next1 = text.index(after: i)
                guard next1 < text.endIndex else {
                    data.append(contentsOf: "=".utf8)
                    break
                }
                let next2 = text.index(after: next1)
                guard next2 < text.endIndex else {
                    data.append(contentsOf: String(text[i...next1]).utf8)
                    break
                }
                let hex = String(text[next1]) + String(text[next2])
                if let byte = UInt8(hex, radix: 16) {
                    data.append(byte)
                    i = text.index(after: next2)
                    continue
                }
                // Soft line break (RFC 2045 §6.7): `=` at end of line, the
                // line break itself removed.
                //
                // #339: this compared a Character against "\r" and "\n" — and
                // Swift folds "\r\n" into ONE extended grapheme cluster that
                // equals NEITHER. So a CRLF soft break (the majority of real
                // wire traffic) fell through to the "not a valid escape" path
                // and was emitted verbatim, splitting words across lines. Bare
                // LF happened to work, which is why the defect survived. Same
                // trap `decodeRFC2047` documents for its LWS scan (#125);
                // decompose to scalars rather than compare whole clusters.
                let scalars = String(text[next1]).unicodeScalars
                if scalars.allSatisfy({ $0 == "\r" || $0 == "\n" }) {
                    i = text.index(after: next1)
                    continue
                }
                data.append(contentsOf: "=".utf8)
                i = next1
                continue
            }
            data.append(contentsOf: String(ch).utf8)
            i = text.index(after: i)
        }
        return data
    }

    /// Map charset name to Swift String.Encoding.
    static func stringEncoding(for charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "utf-8", "utf8":
            return .utf8
        case "iso-8859-1", "latin1":
            return .isoLatin1
        case "iso-8859-2":
            return .isoLatin2
        case "iso-2022-jp":
            return .iso2022JP
        case "euc-jp":
            return .japaneseEUC
        case "shift_jis", "shift-jis":
            return .shiftJIS
        case "big5":
            let cfEnc = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)
            )
            return String.Encoding(rawValue: cfEnc)
        case "gb2312", "gbk", "gb18030":
            let cfEnc = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
            return String.Encoding(rawValue: cfEnc)
        case "windows-1252", "cp1252":
            return .windowsCP1252
        case "us-ascii", "ascii":
            return .ascii
        default:
            return .utf8
        }
    }
}
