import Foundation

/// Full email content parsed from an .emlx file.
public struct EmailContent: Sendable {
    public let subject: String
    public let sender: String
    public let toRecipients: [String]
    public let ccRecipients: [String]
    public let date: String
    public let messageId: String
    /// The `In-Reply-To` Message-ID header (#198), or `""` when absent. Used by
    /// `export_emails_markdown` to populate the `in_reply_to` frontmatter field
    /// (previously hard-coded empty) so reply threading works.
    public let inReplyTo: String
    public let textBody: String?
    public let htmlBody: String?
    public let rawSource: Data?
    /// #274 — true when the content was parsed from a `.partial.emlx` (Mail
    /// has not fully downloaded the message body yet). An empty body from a
    /// partial file means "not downloaded", NOT "empty message".
    public let fromPartialEmlx: Bool

    public init(
        subject: String,
        sender: String,
        toRecipients: [String],
        ccRecipients: [String],
        date: String,
        messageId: String,
        inReplyTo: String,
        textBody: String?,
        htmlBody: String?,
        rawSource: Data?,
        fromPartialEmlx: Bool = false
    ) {
        self.subject = subject
        self.sender = sender
        self.toRecipients = toRecipients
        self.ccRecipients = ccRecipients
        self.date = date
        self.messageId = messageId
        self.inReplyTo = inReplyTo
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.rawSource = rawSource
        self.fromPartialEmlx = fromPartialEmlx
    }
}

extension EmlxParser {

    /// Read and parse a complete email from its .emlx file.
    ///
    /// - Parameters:
    ///   - rowId: The message ROWID from the Envelope Index.
    ///   - mailboxURL: The raw mailbox URL from the database.
    ///   - format: "html" (default), "text", or "source".
    /// - Returns: Parsed email content.
    /// - Throws: `MailSQLiteError` if the file cannot be found or parsed.
    public static func readEmail(
        rowId: Int,
        mailboxURL: String,
        format: String = "html"
    ) throws -> EmailContent {
        guard let resolved = resolveEmlxPathDetailed(rowId: rowId, mailboxURL: mailboxURL) else {
            throw MailSQLiteError.emlxNotFound(
                messageId: rowId,
                path: "Could not resolve .emlx path for message \(rowId)"
            )
        }
        let path = resolved.path
        let isPartial = resolved.isPartial

        let fileData = try Data(contentsOf: URL(fileURLWithPath: path))
        let messageData = try EmlxFormat.extractMessageData(from: fileData)

        // For "source" format, return the raw RFC 822 data
        if format == "source" {
            let headers = RFC822Parser.parseHeaders(from: messageData)
            return EmailContent(
                subject: headers["subject"] ?? "",
                sender: headers["from"] ?? "",
                toRecipients: parseAddressList(headers["to"]),
                ccRecipients: parseAddressList(headers["cc"]),
                date: headers["date"] ?? "",
                messageId: headers["message-id"] ?? "",
                inReplyTo: headers["in-reply-to"] ?? "",
                textBody: nil,
                htmlBody: nil,
                rawSource: messageData,
                fromPartialEmlx: isPartial
            )
        }

        // Parse headers
        let headers = RFC822Parser.parseHeaders(from: messageData)

        // Parse body
        guard let bodyOffset = RFC822Parser.headerBodySplitOffset(in: messageData) else {
            return EmailContent(
                subject: headers["subject"] ?? "",
                sender: headers["from"] ?? "",
                toRecipients: parseAddressList(headers["to"]),
                ccRecipients: parseAddressList(headers["cc"]),
                date: headers["date"] ?? "",
                messageId: headers["message-id"] ?? "",
                inReplyTo: headers["in-reply-to"] ?? "",
                textBody: nil,
                htmlBody: nil,
                rawSource: nil,
                fromPartialEmlx: isPartial
            )
        }

        let bodyData = messageData[bodyOffset...]
        let parsed = MIMEParser.parseBody(Data(bodyData), headers: headers)

        return EmailContent(
            subject: headers["subject"] ?? "",
            sender: headers["from"] ?? "",
            toRecipients: parseAddressList(headers["to"]),
            ccRecipients: parseAddressList(headers["cc"]),
            date: headers["date"] ?? "",
            messageId: headers["message-id"] ?? "",
            inReplyTo: headers["in-reply-to"] ?? "",
            textBody: parsed.textBody,
            htmlBody: parsed.htmlBody,
            rawSource: nil,
            fromPartialEmlx: isPartial
        )
    }

    /// Parse a comma-separated address list into individual addresses.
    private static func parseAddressList(_ value: String?) -> [String] {
        guard let value = value, !value.isEmpty else { return [] }
        return value.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}
