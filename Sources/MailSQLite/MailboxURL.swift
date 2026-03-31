import Foundation

/// Parsed components of a Mail.app mailbox URL.
///
/// Mailbox URLs in the Envelope Index follow the format:
/// `<protocol>://<account-uuid>/<percent-encoded-path>`
///
/// Examples:
/// - `imap://E51B96AC-.../[Gmail]/全部郵件`
/// - `ews://ABCE3A85-.../收件匣`
public struct MailboxURL: Sendable {
    /// The account UUID extracted from the URL authority.
    public let accountUUID: String

    /// The percent-decoded mailbox path (e.g., "[Gmail]/全部郵件").
    public let mailboxPath: String

    /// The URL scheme (e.g., "imap", "ews").
    public let scheme: String

    /// Decode a mailbox URL string into its components.
    ///
    /// - Parameter urlString: The raw URL from `mailboxes.url`.
    /// - Returns: Parsed components, or `nil` if the URL is malformed.
    public static func decode(_ urlString: String) -> MailboxURL? {
        // Expected format: scheme://account-uuid/path...
        guard let schemeEnd = urlString.range(of: "://") else {
            return nil
        }

        let scheme = String(urlString[urlString.startIndex..<schemeEnd.lowerBound])
        let afterScheme = urlString[schemeEnd.upperBound...]

        // Split into UUID and path at the first /
        guard let slashIndex = afterScheme.firstIndex(of: "/") else {
            // URL with UUID only, no mailbox path
            return nil
        }

        let uuid = String(afterScheme[afterScheme.startIndex..<slashIndex])
        let encodedPath = String(afterScheme[afterScheme.index(after: slashIndex)...])
        let decodedPath = encodedPath.removingPercentEncoding ?? encodedPath

        return MailboxURL(
            accountUUID: uuid,
            mailboxPath: decodedPath,
            scheme: scheme
        )
    }

    /// Extract the leaf mailbox name (last path component).
    public var mailboxName: String {
        if let lastSlash = mailboxPath.lastIndex(of: "/") {
            return String(mailboxPath[mailboxPath.index(after: lastSlash)...])
        }
        return mailboxPath
    }
}
