import Foundation

/// Parsed email content from MIME body.
public struct ParsedEmailContent: Sendable {
    public let textBody: String?
    public let htmlBody: String?
}

/// Parser for MIME message bodies.
/// Handles text/plain, text/html, multipart/*, and content-transfer-encoding.
public enum MIMEParser {

    /// Parse the body portion of an RFC 822 message given its headers.
    ///
    /// - Parameters:
    ///   - bodyData: The raw body bytes (after header/body split).
    ///   - headers: Parsed headers from RFC822Parser.
    /// - Returns: Extracted text and/or HTML content.
    public static func parseBody(
        _ bodyData: Data,
        headers: [String: String]
    ) -> ParsedEmailContent {
        let contentType = headers["content-type"] ?? "text/plain"
        let cte = headers["content-transfer-encoding"] ?? "7bit"

        return parsePart(bodyData, contentType: contentType, encoding: cte)
    }

    // MARK: - Part Parsing

    private static func parsePart(
        _ data: Data,
        contentType: String,
        encoding: String
    ) -> ParsedEmailContent {
        let (mimeType, params) = parseContentType(contentType)

        if mimeType.hasPrefix("multipart/") {
            guard let boundary = params["boundary"] else {
                return ParsedEmailContent(textBody: nil, htmlBody: nil)
            }
            return parseMultipart(data, boundary: boundary)
        }

        // Decode transfer encoding
        let decoded = decodeTransferEncoding(data, encoding: encoding)
        let charset = params["charset"] ?? "utf-8"
        let textEncoding = RFC822Parser.stringEncoding(for: charset)
        let text = String(data: decoded, encoding: textEncoding)
            ?? String(data: decoded, encoding: .utf8)
            ?? String(data: decoded, encoding: .ascii)

        if mimeType == "text/html" {
            return ParsedEmailContent(textBody: nil, htmlBody: text)
        } else if mimeType.hasPrefix("text/") {
            return ParsedEmailContent(textBody: text, htmlBody: nil)
        }
        // Non-text parts (attachments, images) — skip
        return ParsedEmailContent(textBody: nil, htmlBody: nil)
    }

    // MARK: - Multipart

    private static func parseMultipart(
        _ data: Data,
        boundary: String
    ) -> ParsedEmailContent {
        let boundaryMarker = "--\(boundary)"
        let endMarker = "--\(boundary)--"

        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii) else {
            return ParsedEmailContent(textBody: nil, htmlBody: nil)
        }

        var textBody: String?
        var htmlBody: String?

        let parts = text.components(separatedBy: boundaryMarker)

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("--") { continue }

            // Each part has its own headers + body
            let partData = Data(part.utf8)
            guard let splitOffset = RFC822Parser.headerBodySplitOffset(in: partData) else {
                continue
            }

            let partHeaders = RFC822Parser.parseHeaders(from: partData)
            let partBody = partData[splitOffset...]

            let partCT = partHeaders["content-type"] ?? "text/plain"
            let partCTE = partHeaders["content-transfer-encoding"] ?? "7bit"

            let result = parsePart(Data(partBody), contentType: partCT, encoding: partCTE)

            if let t = result.textBody, textBody == nil {
                textBody = t
            }
            if let h = result.htmlBody, htmlBody == nil {
                htmlBody = h
            }
        }

        return ParsedEmailContent(textBody: textBody, htmlBody: htmlBody)
    }

    // MARK: - Content-Type Parsing

    /// Parse a Content-Type header value into MIME type and parameters.
    static func parseContentType(_ value: String) -> (String, [String: String]) {
        let parts = value.components(separatedBy: ";")
        let mimeType = parts[0].trimmingCharacters(in: .whitespaces).lowercased()

        var params: [String: String] = [:]
        for i in 1..<parts.count {
            let param = parts[i].trimmingCharacters(in: .whitespaces)
            if let eqIdx = param.firstIndex(of: "=") {
                let key = String(param[param.startIndex..<eqIdx])
                    .trimmingCharacters(in: .whitespaces).lowercased()
                var val = String(param[param.index(after: eqIdx)...])
                    .trimmingCharacters(in: .whitespaces)
                // Remove surrounding quotes
                if val.hasPrefix("\"") && val.hasSuffix("\"") {
                    val = String(val.dropFirst().dropLast())
                }
                params[key] = val
            }
        }
        return (mimeType, params)
    }

    // MARK: - Transfer Encoding

    private static func decodeTransferEncoding(_ data: Data, encoding: String) -> Data {
        switch encoding.lowercased() {
        case "base64":
            let cleaned = String(data: data, encoding: .ascii)?
                .replacingOccurrences(of: "\r\n", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: " ", with: "")
                ?? ""
            return Data(base64Encoded: cleaned) ?? data

        case "quoted-printable":
            guard let text = String(data: data, encoding: .ascii) else { return data }
            return RFC822Parser.decodeQuotedPrintableBytes(text) ?? data

        case "7bit", "8bit", "binary":
            return data

        default:
            return data
        }
    }
}
