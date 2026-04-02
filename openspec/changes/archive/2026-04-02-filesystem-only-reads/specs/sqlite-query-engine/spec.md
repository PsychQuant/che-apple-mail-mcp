## MODIFIED Requirements

### Requirement: Account UUID to name mapping

The system SHALL build a mapping from account UUID to human-readable account names by reading `~/Library/Mail/V10/MailData/Signatures/AccountsMap.plist` at initialization time. The system SHALL NOT use AppleScript for this mapping. The plist maps each UUID to an `AccountURL` field containing the account's email address (percent-encoded). The system SHALL use the decoded email address as the account display name.

#### Scenario: Mapping built from AccountsMap.plist

- **WHEN** the EnvelopeIndexReader initializes
- **THEN** the system reads `AccountsMap.plist`, extracts each UUID key and its `AccountURL` value, percent-decodes the email from the URL authority, and creates a `[String: String]` dictionary mapping UUIDs to email addresses

#### Scenario: AccountsMap.plist not available

- **WHEN** the `AccountsMap.plist` file does not exist or cannot be read
- **THEN** the system falls back to using UUID strings as account names without blocking or crashing

## ADDED Requirements

### Requirement: List accounts via filesystem

The system SHALL provide account listing by scanning `~/Library/Mail/V10/` for UUID-formatted subdirectories and reading `AccountsMap.plist` for account details. The system SHALL NOT use AppleScript for listing accounts.

#### Scenario: List all accounts

- **WHEN** `list_accounts` is called
- **THEN** the system returns an array of accounts, each containing `name` (email address from AccountsMap.plist) and the UUID, derived entirely from filesystem scanning

### Requirement: List mailboxes via SQLite

The system SHALL list mailboxes by querying the `mailboxes` table in the Envelope Index. The system SHALL decode mailbox URLs to extract human-readable mailbox names and account associations.

#### Scenario: List all mailboxes

- **WHEN** `list_mailboxes` is called without an account filter
- **THEN** the system queries all rows from the `mailboxes` table and returns decoded mailbox names with total_count and unread_count

#### Scenario: List mailboxes for specific account

- **WHEN** `list_mailboxes` is called with `account_name`
- **THEN** the system filters mailbox URLs by the corresponding account UUID and returns only that account's mailboxes

### Requirement: List emails via SQLite

The system SHALL list emails in a mailbox by querying the Envelope Index database, joining `messages`, `subjects`, `addresses`, and `mailboxes` tables. The system SHALL NOT use AppleScript for listing emails.

#### Scenario: List emails in a mailbox

- **WHEN** `list_emails` is called with `mailbox` and `account_name`
- **THEN** the system returns emails with id, subject, sender, and date_received, ordered by date_received descending, limited by the `limit` parameter

### Requirement: Get unread count via SQLite

The system SHALL return unread counts by reading `mailboxes.unread_count` from the Envelope Index. The system SHALL NOT use AppleScript for unread counts.

#### Scenario: Unread count for specific mailbox

- **WHEN** `get_unread_count` is called with `mailbox` and `account_name`
- **THEN** the system returns the `unread_count` value from the matching mailbox row

#### Scenario: Total unread count across all mailboxes

- **WHEN** `get_unread_count` is called without filters
- **THEN** the system returns the sum of `unread_count` across all mailbox rows

### Requirement: List attachments via SQLite

The system SHALL list email attachments by querying the `attachments` table in the Envelope Index, joined with `messages`. The system SHALL NOT use AppleScript for listing attachments.

#### Scenario: List attachments for an email

- **WHEN** `list_attachments` is called with a message `id`
- **THEN** the system queries the `attachments` table for rows where `message` equals the ROWID, returning attachment `name` and `attachment_id`

### Requirement: Get email metadata via SQLite

The system SHALL provide email metadata (read status, flagged status, size, deleted status, conversation_id) by querying the `messages` table directly. The system SHALL NOT use AppleScript for metadata retrieval.

#### Scenario: Get metadata for a message

- **WHEN** `get_email_metadata` is called with a message `id`
- **THEN** the system queries the `messages` table for the row with that ROWID and returns read, flagged, deleted, size, and date_received fields

### Requirement: List VIP senders via filesystem

The system SHALL list VIP senders by reading `~/Library/Mail/V10/MailData/VIPMailboxes.plist`. The system SHALL NOT use AppleScript for VIP listing.

#### Scenario: List VIP senders

- **WHEN** `list_vip_senders` is called
- **THEN** the system reads VIPMailboxes.plist and returns the list of VIP email addresses
