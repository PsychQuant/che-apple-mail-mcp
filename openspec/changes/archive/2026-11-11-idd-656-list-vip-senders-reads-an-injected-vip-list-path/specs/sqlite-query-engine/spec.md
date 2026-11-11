## MODIFIED Requirements

### Requirement: List VIP senders via filesystem

The system SHALL list VIP senders by reading `~/Library/Mail/V10/MailData/VIPMailboxes.plist`, except when the reader (or the server that opens it) was built with a VIP list path (a test seam): then it SHALL read that file instead and SHALL NOT read the user's VIP list. A VIP list that is missing or cannot be parsed SHALL be listed as empty. The system SHALL NOT use AppleScript for VIP listing.

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

##### Example: list_vip_senders answers from the server's VIP list path
- **GIVEN** a server built over a fixture index with a VIP list path whose plist holds the one entry `{"address": "vip@example.invalid"}`
- **WHEN** `list_vip_senders` is called
- **THEN** the result is a JSON array holding exactly that entry

##### Example: without an injected path the user's VIP list is read
- **GIVEN** no VIP list path and no test override of the mail storage path
- **WHEN** the default VIP list path is resolved
- **THEN** it is `<home>/Library/Mail/V10/MailData/VIPMailboxes.plist`

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
