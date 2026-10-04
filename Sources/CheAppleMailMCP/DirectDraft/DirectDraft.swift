import CryptoKit
import Foundation

/// #472 — pure parts of the EXPERIMENTAL direct-draft path.
///
/// The #463 spike wrote a draft straight into Mail's local store and showed
/// that toggling the draft's own read status makes Mail upload it, with a
/// server copy indistinguishable from Mail's own drafts. This file holds what
/// needs no store or AppleScript: who is eligible, the MIME in the layout Mail
/// uses for drafts it saves, the .emlx framing, and the message-id hash the
/// Envelope Index keys on. Opt-in only: `CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1`.
enum DirectDraft {
    static let envKey = "CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT"

    static var isEnabled: Bool { ProcessInfo.processInfo.environment[envKey] == "1" }

    /// Mail's own first-save value for a draft (#463 S3/S5): read | draft (0x40)
    /// | 0x30000 | pending-sync (0x2000000) | high 0x2_0000_0000.
    static let draftFlags: Int64 = 8_623_685_697

    // MARK: - Eligibility (closed list — anything else takes the GUI path)

    enum Ineligible: Equatable {
        case disabled, format, attachments, ccOrBcc, noRecipient, displayName, unsupportedAddress,
             emptySubject, missingFromAddress, fromNotBare

        var reason: String {
            switch self {
            case .disabled: return "\(DirectDraft.envKey) is not set"
            case .format: return "only plain text is written directly"
            case .attachments: return "attachments are not written directly"
            case .ccOrBcc: return "cc/bcc are not written directly"
            case .noRecipient: return "no To recipient"
            case .displayName: return "display-name recipients are not written directly"
            case .unsupportedAddress: return "a recipient is not a plain addr-spec"
            case .emptySubject: return "empty subject"
            case .missingFromAddress: return "from_address is required to pick the account"
            case .fromNotBare: return "from_address must be a bare address"
            }
        }
    }

    static func eligibility(enabled: Bool, format: BodyFormat, to: [String], cc: [String], bcc: [String],
                            attachments: [String], subject: String, fromAddress: String?) -> Ineligible? {
        guard enabled else { return .disabled }
        guard format == .plain else { return .format }
        guard attachments.isEmpty else { return .attachments }
        guard cc.isEmpty, bcc.isEmpty else { return .ccOrBcc }
        guard !to.isEmpty else { return .noRecipient }
        for raw in to {
            let parsed = parseRecipient(raw)
            if parsed.name != nil || raw.trimmingCharacters(in: .whitespaces) != parsed.address {
                return .displayName
            }
            if !isSimpleAddrSpec(parsed.address) { return .unsupportedAddress }
        }
        guard !subject.isEmpty else { return .emptySubject }
        guard let from = fromAddress, !from.isEmpty else { return .missingFromAddress }
        let parsedFrom = parseRecipient(from)
        guard parsedFrom.name == nil, from.trimmingCharacters(in: .whitespaces) == parsedFrom.address,
              isSimpleAddrSpec(parsedFrom.address) else { return .fromNotBare }
        return nil
    }

    // MARK: - MIME

    struct Message {
        let mime: Data
        let messageIdNoBrackets: String
        var size: Int { mime.count }
    }

    /// The draft in the layout Mail writes for drafts it saves (#472 design):
    /// `multipart/alternative` with an empty `text/plain` part and the body in
    /// `text/html`, LF line endings, `X-Uniform-Type-Identifier: com.apple.mail-draft`.
    /// Non-ASCII goes out as UTF-8: RFC 2047 encoded words in headers,
    /// quoted-printable in the body.
    static func buildMessage(fromName: String?, fromAddress: String, to: [String], subject: String, body: String,
                             date: Date, documentUUID: UUID, messageIdLocalPart: UUID, boundary: UUID,
                             mailVersion: String, timeZone: TimeZone = .current) -> Message {
        let domain = fromAddress.split(separator: "@").last.map(String.init) ?? "localhost"
        let messageId = "\(messageIdLocalPart.uuidString)@\(domain)"
        let marker = "Apple-Mail=_\(boundary.uuidString)"
        let versionComment = mailVersion
            .replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")

        let headers = [
            "Subject: \(encodeHeaderText(subject))",
            "Mime-Version: 1.0 (Mac OS X Mail \(versionComment))",
            "Content-Type: multipart/alternative;\n\tboundary=\"\(marker)\"",
            "X-Apple-Base-Url: x-msg://16/",
            "X-Universally-Unique-Identifier: \(documentUUID.uuidString)",
            "X-Apple-Mail-Remote-Attachments: YES",
            "From: \(formatMailbox(name: fromName, address: fromAddress))",
            "X-Apple-Windows-Friendly: 1",
            "Date: \(rfc5322Date(date, timeZone: timeZone))",
            "X-Apple-Mail-Signature: ",
            "Message-Id: <\(messageId)>",
            "X-Uniform-Type-Identifier: com.apple.mail-draft",
            "To: \(to.joined(separator: ", "))",
        ]

        let html = "<html><head></head><body dir=\"auto\" style=\"overflow-wrap: break-word; "
            + "-webkit-nbsp-mode: space; line-break: after-white-space;\">\n"
            + body.components(separatedBy: "\n").map(escapeHTML).joined(separator: "<br>\n")
            + "\n</body></html>"
        let ascii = html.unicodeScalars.allSatisfy { $0.isASCII }
        let htmlPart = ascii
            ? "Content-Transfer-Encoding: 7bit\nContent-Type: text/html;\n\tcharset=us-ascii\n\n\(html)"
            : "Content-Transfer-Encoding: quoted-printable\nContent-Type: text/html;\n\tcharset=utf-8\n\n"
                + quotedPrintable(Data(html.utf8))

        let text = headers.joined(separator: "\n") + "\n\n"
            + "--\(marker)\nContent-Transfer-Encoding: 7bit\nContent-Type: text/plain;\n\tcharset=us-ascii\n\n\n"
            + "--\(marker)\n\(htmlPart)\n"
            + "--\(marker)--\n"
        return Message(mime: Data(text.utf8), messageIdNoBrackets: messageId)
    }

    // MARK: - .emlx and index keys

    /// `<byte count padded to 10>\n<message><plist>` — the framing Mail uses.
    static func emlx(mime: Data, flags: Int64, date: Date) -> Data {
        let seconds = Int64(date.timeIntervalSince1970)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>date-last-viewed</key>
        \t<integer>\(seconds)</integer>
        \t<key>date-received</key>
        \t<integer>\(seconds)</integer>
        \t<key>flags</key>
        \t<integer>\(flags)</integer>
        </dict>
        </plist>

        """
        var out = Data((String(mime.count).padding(toLength: 10, withPad: " ", startingAt: 0) + "\n").utf8)
        out.append(mime)
        out.append(Data(plist.utf8))
        return out
    }

    /// `messages.message_id`: the first 8 bytes of MD5(Message-Id without the
    /// angle brackets), read little-endian as a signed 64-bit integer (#463 S3,
    /// matched on 400/400 existing rows).
    static func messageIdHash(_ messageIdNoBrackets: String) -> Int64 {
        let digest = Array(Insecure.MD5.hash(data: Data(messageIdNoBrackets.utf8)))
        var value: UInt64 = 0
        for i in (0..<8).reversed() { value = (value << 8) | UInt64(digest[i]) }
        return Int64(bitPattern: value)
    }

    // MARK: - Encoders

    static func encodeHeaderText(_ text: String) -> String {
        if text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) { return text }
        return encodedWords(text)
    }

    /// RFC 2047 `B` encoded words of at most 45 UTF-8 bytes each (60 base64
    /// characters), split on character boundaries and folded with LF + space.
    static func encodedWords(_ text: String) -> String {
        var words: [String] = []
        var chunk = Data()
        for character in text {
            let bytes = Data(String(character).utf8)
            if chunk.count + bytes.count > 45, !chunk.isEmpty {
                words.append("=?utf-8?B?\(chunk.base64EncodedString())?=")
                chunk = Data()
            }
            chunk.append(bytes)
        }
        if !chunk.isEmpty { words.append("=?utf-8?B?\(chunk.base64EncodedString())?=") }
        return words.joined(separator: "\n ")
    }

    static func formatMailbox(name: String?, address: String) -> String {
        guard let name, !name.isEmpty else { return address }
        if !name.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) {
            return "\(encodedWords(name)) <\(address)>"
        }
        let specials = CharacterSet(charactersIn: "()<>[]:;@\\,.\"")
        if name.rangeOfCharacter(from: specials) != nil {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(address)>"
        }
        return "\(name) <\(address)>"
    }

    static func rfc5322Date(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    static func escapeHTML(_ line: String) -> String {
        line.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Quoted-printable (RFC 2045) over LF-separated lines: soft breaks keep
    /// every line at most 76 characters and never split an `=XX` escape.
    static func quotedPrintable(_ data: Data) -> String {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        return lines.map { line -> String in
            var tokens: [String] = []
            let bytes = Array(line)
            for (i, b) in bytes.enumerated() {
                let last = i == bytes.count - 1
                if (b == 0x20 || b == 0x09) && !last {
                    tokens.append(String(UnicodeScalar(b)))
                } else if b >= 33 && b <= 126 && b != 0x3D {
                    tokens.append(String(UnicodeScalar(b)))
                } else {
                    tokens.append(String(format: "=%02X", b))
                }
            }
            var out: [String] = []
            var current = ""
            for t in tokens {
                if current.count + t.count > 75 {
                    out.append(current + "=")
                    current = ""
                }
                current += t
            }
            out.append(current)
            return out.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}
