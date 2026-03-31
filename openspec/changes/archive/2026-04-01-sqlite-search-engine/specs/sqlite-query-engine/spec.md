## ADDED Requirements

### Requirement: SQLite database connection management

The system SHALL open `~/Library/Mail/V10/MailData/Envelope Index` in read-only mode using `SQLITE_OPEN_READONLY`. The system SHALL verify the database file exists and is accessible before attempting to open it. If the file is not accessible, the system SHALL return an error message stating that Full Disk Access permission is required.

#### Scenario: Successful database connection

- **WHEN** the MCP server initializes and the Envelope Index database is accessible
- **THEN** the system opens a read-only SQLite connection and prepares reusable statements for search queries

#### Scenario: Database file not accessible

- **WHEN** the MCP server attempts to open the Envelope Index and the file does not exist or access is denied
- **THEN** the system returns an error indicating Full Disk Access permission is required for the terminal application

#### Scenario: Database file path with V10

- **WHEN** the system resolves the Envelope Index path
- **THEN** the system uses `~/Library/Mail/V10/MailData/Envelope Index` with the V10 path segment defined as a named constant

### Requirement: Account UUID to name mapping

The system SHALL build a mapping from account UUID (directory names under `~/Library/Mail/V10/`) to human-readable account names at initialization time. The system SHALL use AppleScript to query account names and match them to UUID directories.

#### Scenario: Mapping built at startup

- **WHEN** the EnvelopeIndexReader initializes
- **THEN** the system creates a `[String: String]` dictionary mapping account UUIDs to account names by combining AppleScript account query results with filesystem directory listing

#### Scenario: Unknown account UUID encountered

- **WHEN** a mailbox URL contains an account UUID not present in the mapping
- **THEN** the system uses the UUID string itself as the account name fallback

### Requirement: Search emails by subject

The system SHALL search emails by matching the query string against the `subjects.subject` column using case-insensitive `LIKE` pattern matching. The system SHALL exclude deleted messages (`messages.deleted = 0`).

#### Scenario: Subject search across all accounts

- **WHEN** `search_emails` is called with `query: "invoice"` and no mailbox or account filter
- **THEN** the system returns all non-deleted messages whose subject contains "invoice", with each result including id, subject, sender address, sender name, date_received, account_name, and mailbox name

#### Scenario: Subject search with account filter

- **WHEN** `search_emails` is called with `query: "meeting"` and `account_name: "Gmail"`
- **THEN** the system returns only messages from mailboxes belonging to the Gmail account whose subject contains "meeting"

#### Scenario: Subject search with mailbox filter

- **WHEN** `search_emails` is called with `query: "report"`, `account_name: "Gmail"`, and `mailbox: "INBOX"`
- **THEN** the system returns only messages in the Gmail INBOX whose subject contains "report"

### Requirement: Search emails by sender

The system SHALL search emails by matching the query string against both `addresses.address` (email) and `addresses.comment` (display name) of the sender using case-insensitive `LIKE` pattern matching.

#### Scenario: Sender search by email address

- **WHEN** `search_emails` is called with `query: "john@example.com"` and `field: "sender"`
- **THEN** the system returns messages where the sender's email address contains "john@example.com"

#### Scenario: Sender search by display name

- **WHEN** `search_emails` is called with `query: "John"` and `field: "sender"`
- **THEN** the system returns messages where the sender's display name contains "John"

### Requirement: Search emails by recipient

The system SHALL search emails by matching the query string against recipient addresses (both `addresses.address` and `addresses.comment`) via the `recipients` join table. The recipient type column values are: 0 = To, 1 = CC.

#### Scenario: Recipient search finds To recipients

- **WHEN** `search_emails` is called with `query: "alice@example.com"` and `field: "recipient"`
- **THEN** the system returns messages where any To or CC recipient's address contains "alice@example.com"

#### Scenario: Recipient-only search excludes sender matches

- **WHEN** `search_emails` is called with `query: "bob@example.com"` and `field: "recipient"`, and bob@example.com appears only as a sender in some messages
- **THEN** the system returns only messages where bob@example.com is a To or CC recipient, not messages where bob@example.com is the sender

### Requirement: Search with default field "any"

The system SHALL support a `field` parameter with values `subject`, `sender`, `recipient`, and `any`. When `field` is `any` (the default) or omitted, the system SHALL search across subject, sender address, sender name, and recipient addresses simultaneously.

#### Scenario: Default field searches all fields

- **WHEN** `search_emails` is called with `query: "alice"` and no `field` parameter
- **THEN** the system returns messages where "alice" appears in the subject, sender address, sender display name, or any recipient address/name

### Requirement: Date range filtering

The system SHALL support `date_from` and `date_to` parameters for filtering by `messages.date_received`. These parameters accept ISO 8601 date strings (e.g., `2026-01-01` or `2026-01-01T00:00:00+08:00`) and are converted to Unix timestamps for comparison.

#### Scenario: Filter by date range

- **WHEN** `search_emails` is called with `date_from: "2026-03-01"` and `date_to: "2026-03-31"`
- **THEN** the system returns only messages received between March 1 and March 31, 2026 (inclusive, using local timezone when no timezone offset is provided)

#### Scenario: Open-ended date range

- **WHEN** `search_emails` is called with `date_from: "2026-01-01"` and no `date_to`
- **THEN** the system returns messages received on or after January 1, 2026 with no upper date bound

### Requirement: Search result sorting and limiting

The system SHALL sort search results by `messages.date_received` in descending order by default (newest first). The system SHALL support a `sort` parameter with values `desc` (default) and `asc`. The system SHALL limit results to the value of the `limit` parameter (default: 50).

#### Scenario: Default sort order

- **WHEN** `search_emails` is called without a `sort` parameter
- **THEN** results are ordered by date received, newest first

#### Scenario: Custom limit

- **WHEN** `search_emails` is called with `limit: 10`
- **THEN** at most 10 results are returned

### Requirement: Search result format backward compatibility

The system SHALL return search results with at minimum the fields: `id`, `subject`, `sender`, `date_received`, `account_name`, `mailbox`. The system SHALL additionally include a `to` field containing the primary To recipient addresses. The `id` field SHALL contain the message ROWID which is directly compatible with AppleScript's `id of message`.

#### Scenario: Result fields include both legacy and new fields

- **WHEN** a search returns results
- **THEN** each result contains `id` (integer as string), `subject` (string), `sender` (email address string), `date_received` (ISO 8601 formatted string), `account_name` (human-readable string), `mailbox` (decoded mailbox name string), and `to` (array of recipient email address strings)

### Requirement: Mailbox URL decoding

The system SHALL decode `mailboxes.url` to extract the account UUID and human-readable mailbox path. The URL format is `<protocol>://<account-uuid>/<percent-encoded-path>`. The system SHALL percent-decode the path and strip known prefixes (e.g., `[Gmail]/`) to produce user-facing mailbox names that match AppleScript mailbox names.

#### Scenario: IMAP mailbox URL decoding

- **WHEN** the system encounters mailbox URL `imap://E51B96AC-9499-4FCC-9638-18F2A300EBFE/%5BGmail%5D/%E5%85%A8%E9%83%A8%E9%83%B5%E4%BB%B6`
- **THEN** the system extracts account UUID `E51B96AC-9499-4FCC-9638-18F2A300EBFE` and mailbox name `全部郵件` (under `[Gmail]`)

#### Scenario: EWS mailbox URL decoding

- **WHEN** the system encounters mailbox URL `ews://ABCE3A85-06BE-43BC-9B84-2CA6F325612F/%E6%94%B6%E4%BB%B6%E5%8C%A3`
- **THEN** the system extracts account UUID `ABCE3A85-06BE-43BC-9B84-2CA6F325612F` and mailbox name `收件匣`
