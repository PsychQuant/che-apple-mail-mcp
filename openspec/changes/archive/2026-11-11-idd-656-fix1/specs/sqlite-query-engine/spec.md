## MODIFIED Requirements

### Requirement: List VIP senders via filesystem

The system SHALL list VIP senders by reading `MailData/VIPMailboxes.plist` under the mail storage path, which is `~/Library/Mail/V10` unless a test overrides it (`mailStoragePathOverride`), so in production the file is `~/Library/Mail/V10/MailData/VIPMailboxes.plist`. When the reader was built with a VIP list path (a test seam), it SHALL read that file instead, and a reader that opened SHALL NOT read the user's VIP list. A VIP list file that does not exist SHALL be listed as empty. The system SHALL NOT use AppleScript for VIP listing.

#### Scenario: List VIP senders

- **WHEN** `list_vip_senders` is called
- **THEN** the system reads VIPMailboxes.plist and returns the list of VIP email addresses

#### Scenario: A reader built with a VIP list path reads only that file

- **WHEN** the reader was built with a VIP list path and VIP senders are listed
- **THEN** the system SHALL return the entries of that file
- **AND** a path to a file that does not exist SHALL give an empty list

##### Example: an injected VIP list is the one listed
- **GIVEN** a reader built with a VIP list path whose plist holds one entry, the dictionary `{"address": "vip@example.invalid"}`
- **WHEN** VIP senders are listed, and then again from a reader built with a path where no file exists
- **THEN** the first listing is exactly that one entry and the second is empty

#### Scenario: A server built with a VIP list path answers list_vip_senders from it

- **WHEN** the server was built with a VIP list path, its reader opened, and `list_vip_senders` is called
- **THEN** the result SHALL be the entries of that file
- **AND** no AppleScript SHALL run

##### Example: list_vip_senders answers from the server's VIP list path
- **GIVEN** a server built over a fixture index with a VIP list path whose plist holds the one entry `{"address": "vip@example.invalid"}`, and script seams that fail any AppleScript
- **WHEN** `list_vip_senders` is called
- **THEN** the result is a JSON array holding exactly that entry, and no script ran

#### Scenario: Without a VIP list path the reader reads under the mail storage path

- **WHEN** the reader was built without a VIP list path and VIP senders are listed
- **THEN** the system SHALL read `MailData/VIPMailboxes.plist` under the mail storage path
- **AND** with no test override of the mail storage path that file SHALL be `~/Library/Mail/V10/MailData/VIPMailboxes.plist`

##### Example: without an injected path the user's VIP list is read
- **GIVEN** no VIP list path and no test override of the mail storage path
- **WHEN** the default VIP list path is resolved
- **THEN** it is `<home>/Library/Mail/V10/MailData/VIPMailboxes.plist`

##### Example: the default follows the test override of the mail storage path
- **GIVEN** the mail storage path overridden to a test directory whose `MailData/VIPMailboxes.plist` holds the one entry `{"address": "override@example.invalid"}`, and a reader built without a VIP list path
- **WHEN** VIP senders are listed
- **THEN** the listing is exactly that entry

<!-- @trace
source: filesystem-only-reads
updated: 2026-04-02
code:
  - Tests/MailSQLiteTests/FilesystemQueryTests.swift
  - Sources/MailSQLite/EmlxParser.swift
  - Tests/MailSQLiteTests/StartupTests.swift
  - Sources/CheAppleMailMCP/Server.swift
  - Sources/MailSQLite/AccountMapper.swift
  - Sources/MailSQLite/EnvelopeIndexReader.swift
  - Tests/MailSQLiteTests/AccountMapperTests.swift
  - Tests/MailSQLiteTests/EmlxReadersTests.swift
-->
