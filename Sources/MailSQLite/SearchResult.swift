import Foundation

/// A single email search result from the Envelope Index.
public struct SearchResult: Sendable {
    public let id: Int
    public let subject: String
    public let senderAddress: String
    public let senderName: String
    public let dateReceived: Date
    public let accountName: String
    public let mailboxPath: String
    public let isRead: Bool
    public let isFlagged: Bool
    public let toRecipients: [String]
}

/// Parameters for searching emails via SQLite.
public struct SearchParameters: Sendable {
    /// The search query string.
    public var query: String

    /// Which field(s) to search. Default is `.any`.
    public var field: SearchField

    /// Optional account name filter.
    public var accountName: String?

    /// Optional mailbox name filter.
    public var mailbox: String?

    /// Optional start date (inclusive).
    public var dateFrom: Date?

    /// Optional end date (inclusive).
    public var dateTo: Date?

    /// Sort order. Default is `.desc` (newest first).
    public var sort: SortOrder

    /// Maximum number of results. Default is 50.
    public var limit: Int

    public init(
        query: String,
        field: SearchField = .any,
        accountName: String? = nil,
        mailbox: String? = nil,
        dateFrom: Date? = nil,
        dateTo: Date? = nil,
        sort: SortOrder = .desc,
        limit: Int = 50
    ) {
        self.query = query
        self.field = field
        self.accountName = accountName
        self.mailbox = mailbox
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.sort = sort
        self.limit = limit
    }
}

/// Which field(s) to search.
public enum SearchField: String, Sendable {
    case subject
    case sender
    case recipient
    case any
}

/// Sort order for search results.
public enum SortOrder: String, Sendable {
    case asc
    case desc
}
