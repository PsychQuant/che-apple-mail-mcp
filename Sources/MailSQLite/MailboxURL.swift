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
    ///
    /// **Lossy by construction**: the whole path is decoded in one pass, so a
    /// percent-encoded slash inside a mailbox *name* (`R%26D%2FSent`) becomes
    /// indistinguishable from a hierarchy separator. This is the representation
    /// `search_emails` reports and it is kept as-is for compatibility; anything
    /// that needs to reason about hierarchy must use `pathComponents` (#344).
    public let mailboxPath: String

    /// The mailbox path split into hierarchy components, each independently
    /// percent-decoded.
    ///
    /// Splitting happens on the **encoded** path, so a `%2F` stays inside the
    /// component it belongs to and can never masquerade as a separator:
    ///
    /// - `imap://UUID/R%26D%2FSent` → `["R&D/Sent"]`  (one mailbox, literal `/`)
    /// - `imap://UUID/R%26D/Sent`   → `["R&D", "Sent"]` (two levels)
    ///
    /// Empty segments are preserved (`A//B` → `["A", "", "B"]`): dropping them
    /// would collapse two distinct paths into one, which is the very loss this
    /// accessor exists to avoid.
    public let pathComponents: [String]

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
        // Split FIRST, decode each piece SECOND — the order is the whole point.
        let components = encodedPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).removingPercentEncoding ?? String($0) }

        return MailboxURL(
            accountUUID: uuid,
            mailboxPath: decodedPath,
            pathComponents: components,
            scheme: scheme
        )
    }

    /// The leaf mailbox name — the last hierarchy component.
    ///
    /// Derived from `pathComponents`, never from `mailboxPath` (#358). Taking
    /// the substring after the last `/` of the decoded path is the same defect
    /// #344 removed from the mailbox filter: a mailbox literally NAMED
    /// `R&D/Sent` (raw `R%26D%2FSent`) would report its leaf as `Sent`.
    ///
    /// This accessor had no consumers when the flaw was found, which is exactly
    /// why it was fixed rather than deleted — it reads naturally enough that
    /// deleting it invites the next caller to write `mailboxPath.split("/").last`
    /// themselves and reintroduce the bug in their own code.
    public var mailboxName: String {
        pathComponents.last ?? mailboxPath
    }
}
