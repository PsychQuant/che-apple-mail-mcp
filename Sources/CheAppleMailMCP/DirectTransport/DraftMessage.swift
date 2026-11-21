import Foundation

/// The message `append_draft` puts in the server's drafts mailbox (#744).
///
/// A single `text/plain; charset=utf-8` part with CRLF line endings: the
/// structure of a plain-text message Mail itself sends. It is deliberately not
/// the layout Mail writes for the drafts it saves (`multipart/alternative` with
/// an empty plain part and draft-only headers), because `send_draft` submits a
/// draft as stored, and those would reach the recipient (#745).
///
/// Callers validate their input first (`AppendDraftTool.refusal`): nothing here
/// checks for a line break in a header value.
enum DraftMessage {
    struct Built: Equatable {
        let mime: Data
        /// In the form `<local@domain>`.
        let messageID: String
    }

    static func build(fromName: String?, fromAddress: String, to: [String], cc: [String], bcc: [String],
                      subject: String, body: String, date: Date, messageIDLocalPart: UUID,
                      timeZone: TimeZone = .current) -> Built {
        let domain = fromAddress.split(separator: "@").last.map(String.init) ?? "localhost"
        let messageID = "<\(messageIDLocalPart.uuidString)@\(domain)>"
        let content = bodyPart(body)

        var headers = ["From: \(DirectDraft.formatMailbox(name: fromName, address: fromAddress))"]
        for (name, list) in [("To", to), ("Cc", cc), ("Bcc", bcc)] where !list.isEmpty {
            headers.append(DirectDraft.foldedHeaderLine("\(name): \(list.joined(separator: ", "))"))
        }
        headers += [
            DirectDraft.subjectHeader(subject),
            "Date: \(DirectDraft.rfc5322Date(date, timeZone: timeZone))",
            "Message-ID: \(messageID)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: \(content.encoding)",
        ]
        // The helpers fold with LF; the wire form is CRLF throughout.
        let headerBlock = headers.joined(separator: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        var mime = Data(headerBlock.utf8)
        mime.append(Data("\r\n\r\n".utf8))
        mime.append(content.bytes)
        return Built(mime: mime, messageID: messageID)
    }

    /// The body with every line ending made CRLF and one at the end: as is
    /// (`7bit`) when it is ASCII and no line passes the RFC 5322 limit, and
    /// base64 in lines of 76 otherwise.
    static func bodyPart(_ body: String) -> (encoding: String, bytes: Data) {
        var normalised: [UInt8] = []
        let source = Array(body.utf8)
        var index = 0
        while index < source.count {
            let byte = source[index]
            if byte == 0x0D {
                normalised += [0x0D, 0x0A]
                if index + 1 < source.count, source[index + 1] == 0x0A { index += 1 }
            } else if byte == 0x0A {
                normalised += [0x0D, 0x0A]
            } else {
                normalised.append(byte)
            }
            index += 1
        }
        if !(normalised.count >= 2 && normalised.suffix(2) == [0x0D, 0x0A]) { normalised += [0x0D, 0x0A] }

        let ascii = normalised.allSatisfy { $0 < 0x80 }
        let longestLine = normalised.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { $0.last == 0x0D ? $0.count - 1 : $0.count }.max() ?? 0
        if ascii && longestLine <= DirectDraft.maxLineOctets {
            return ("7bit", Data(normalised))
        }
        let encoded = Data(normalised).base64EncodedString(
            options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return ("base64", Data((encoded + "\r\n").utf8))
    }
}
