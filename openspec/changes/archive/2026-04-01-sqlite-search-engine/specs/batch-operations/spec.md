## ADDED Requirements

### Requirement: Batch get emails tool

The system SHALL provide a `get_emails_batch` MCP tool that accepts an array of email identifiers and returns the content of all specified emails in a single MCP response. Each identifier in the array SHALL contain `id`, `mailbox`, and `account_name` fields. The system SHALL process emails in parallel using Swift `TaskGroup` when using the emlx-based reader.

#### Scenario: Batch get with multiple emails

- **WHEN** `get_emails_batch` is called with `emails: [{"id": "100", "mailbox": "INBOX", "account_name": "Gmail"}, {"id": "200", "mailbox": "INBOX", "account_name": "Gmail"}]`
- **THEN** the system returns an array with the full content of both emails, each containing subject, sender, date, body, and recipients

#### Scenario: Batch get with partial failures

- **WHEN** `get_emails_batch` is called with 3 email identifiers and one email's `.emlx` file is missing
- **THEN** the system returns results for the 2 successful emails and an error entry for the failed email, without aborting the entire batch

#### Scenario: Batch get with format parameter

- **WHEN** `get_emails_batch` is called with `format: "text"`
- **THEN** all emails in the batch are returned with plain text body content

#### Scenario: Empty batch request

- **WHEN** `get_emails_batch` is called with an empty `emails` array
- **THEN** the system returns an empty results array

### Requirement: Batch list attachments tool

The system SHALL provide a `list_attachments_batch` MCP tool that accepts an array of email identifiers and returns the attachment list for each email. Since attachment metadata requires AppleScript (`save attachment` paths are managed by Mail.app), this tool SHALL use the existing AppleScript-based `listAttachments` method for each email.

#### Scenario: Batch list attachments

- **WHEN** `list_attachments_batch` is called with `emails: [{"id": "100", "mailbox": "INBOX", "account_name": "Gmail"}, {"id": "200", "mailbox": "Sent", "account_name": "Gmail"}]`
- **THEN** the system returns an array where each entry contains the email identifier and its list of attachments (name, size, MIME type)

#### Scenario: Batch list with email having no attachments

- **WHEN** an email in the batch has no attachments
- **THEN** the entry for that email contains an empty attachments array

#### Scenario: Batch list with partial failures

- **WHEN** one email in the batch cannot be found via AppleScript
- **THEN** the system returns results for successful emails and an error entry for the failed email, without aborting the entire batch

### Requirement: Batch operation size limit

The system SHALL enforce a maximum batch size of 50 items per request for both `get_emails_batch` and `list_attachments_batch`. If the batch exceeds 50 items, the system SHALL return an error indicating the maximum batch size.

#### Scenario: Batch size within limit

- **WHEN** `get_emails_batch` is called with 30 email identifiers
- **THEN** the system processes all 30 emails normally

#### Scenario: Batch size exceeds limit

- **WHEN** `get_emails_batch` is called with 51 email identifiers
- **THEN** the system returns an error: "Batch size exceeds maximum of 50 items"
