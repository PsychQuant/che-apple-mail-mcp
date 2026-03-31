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
        guard let headerEnd = headerBodySplitOffset(in: data) else {
            // No body separator found — treat entire data as headers
            return parseHeaderBlock(data)
        }
        let headerData = data[data.startIndex..<data.index(data.startIndex, offsetBy: headerEnd - data.startIndex - 4 >= 0 ? 0 : 0)]
        // Find the \r\n\r\n boundary
        let splitIdx = findDoubleCRLF(in: data)
        if let idx = splitIdx {
            return parseHeaderBlock(data[data.startIndex..<idx])
        }
        return parseHeaderBlock(data)
    }

    /// Find the byte offset where the body begins (after \r\n\r\n or \n\n).
    /// Returns the offset of the first byte of the body, or nil if not found.
    public static func headerBodySplitOffset(in data: Data) -> Int? {
        let bytes = Array(data)
        // Look for \r\n\r\n
        for i in 0..<(bytes.count - 3) {
            if bytes[i] == 0x0D && bytes[i+1] == 0x0A
                && bytes[i+2] == 0x0D && bytes[i+3] == 0x0A {
                return i + 4
            }
        }
        // Fallback: look for \n\n (some messages use bare LF)
        for i in 0..<(bytes.count - 1) {
            if bytes[i] == 0x0A && bytes[i+1] == 0x0A {
                return i + 2
            }
        }
        return nil
    }

    // MARK: - Private

    private static func findDoubleCRLF(in data: Data) -> Int? {
        let bytes = Array(data)
        for i in 0..<(bytes.count - 3) {
            if bytes[i] == 0x0D && bytes[i+1] == 0x0A
                && bytes[i+2] == 0x0D && bytes[i+3] == 0x0A {
                return i
            }
        }
        // Fallback: bare \n\n
        for i in 0..<(bytes.count - 1) {
            if bytes[i] == 0x0A && bytes[i+1] == 0x0A {
                return i
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
            let decoded = decodeRFC2047(value)
            headers[name] = decoded
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

        while !remaining.isEmpty {
            guard let startRange = remaining.range(of: "=?", options: .literal) else {
                result += remaining
                break
            }

            // Text before the encoded word
            let prefix = remaining[remaining.startIndex..<startRange.lowerBound]
            if lastWasEncodedWord && prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
                // RFC 2047: skip whitespace between consecutive encoded-words
            } else {
                result += prefix
            }

            // Parse =?charset?encoding?text?= structure:
            // After =?, find charset (up to ?), encoding (single char, up to ?),
            // then text (up to ?=)
            let afterEq = remaining[startRange.upperBound...]
            guard let parsed = parseEncodedWord(afterEq) else {
                result += "=?"
                remaining = remaining[startRange.upperBound...]
                lastWasEncodedWord = false
                continue
            }

            var decoded: String?
            if parsed.encoding == "B" {
                decoded = decodeBase64(parsed.text, charset: parsed.charset)
            } else if parsed.encoding == "Q" {
                decoded = decodeQuotedPrintableWord(parsed.text, charset: parsed.charset)
            }

            if let decoded = decoded {
                result += decoded
                lastWasEncodedWord = true
            } else {
                result += String(remaining[startRange.lowerBound..<parsed.endIndex])
                lastWasEncodedWord = false
            }

            remaining = remaining[parsed.endIndex...]
        }

        return result
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

    private static func decodeBase64(_ text: String, charset: String) -> String? {
        guard let data = Data(base64Encoded: text) else { return nil }
        let encoding = stringEncoding(for: charset)
        return String(data: data, encoding: encoding)
    }

    private static func decodeQuotedPrintableWord(_ text: String, charset: String) -> String? {
        // In encoded-words, _ represents space (not literal underscore)
        let withSpaces = text.replacingOccurrences(of: "_", with: " ")
        guard let data = decodeQuotedPrintableBytes(withSpaces) else { return nil }
        let encoding = stringEncoding(for: charset)
        return String(data: data, encoding: encoding)
    }

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
                // Soft line break (=\r\n or =\n) — skip
                if text[next1] == "\r" || text[next1] == "\n" {
                    i = next1
                    if text[next1] == "\r" && next2 < text.endIndex && text[next2] == "\n" {
                        i = text.index(after: next2)
                    } else {
                        i = text.index(after: next1)
                    }
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
