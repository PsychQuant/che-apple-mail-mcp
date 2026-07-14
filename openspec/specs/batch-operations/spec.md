# batch-operations Specification

## Purpose

TBD - created by archiving change 'sqlite-search-engine'. Update Purpose after archive.

## Requirements

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


<!-- @trace
source: sqlite-search-engine
updated: 2026-04-01
code:
  - .remember/logs/autonomous/save-000640.log
  - .remember/logs/autonomous/save-053348.log
  - .remember/logs/autonomous/save-002310.log
  - .remember/logs/autonomous/save-002351.log
  - .remember/logs/autonomous/save-001649.log
  - .remember/logs/autonomous/save-053413.log
  - .remember/logs/autonomous/save-002438.log
  - .remember/logs/autonomous/save-053450.log
  - .remember/logs/autonomous/save-002236.log
  - .remember/logs/autonomous/save-053342.log
  - .remember/tmp/save-session.pid
  - .remember/logs/autonomous/save-000421.log
  - .remember/logs/autonomous/save-000520.log
  - Tests/MailSQLiteTests/EmlxFormatTests.swift
  - .remember/logs/autonomous/save-053405.log
  - .agents/skills/spectra-ingest/SKILL.md
  - .remember/logs/autonomous/save-053523.log
  - logs/mcptools/debug/debug-report-20260316-001500.md
  - .remember/logs/autonomous/save-001229.log
  - Tests/MailSQLiteTests/SearchTests.swift
  - .remember/logs/autonomous/save-002340.log
  - .remember/logs/autonomous/save-001250.log
  - .remember/logs/autonomous/save-002328.log
  - .remember/logs/autonomous/save-003320.log
  - .remember/logs/autonomous/save-003259.log
  - .remember/logs/autonomous/save-001939.log
  - .remember/logs/autonomous/save-001502.log
  - .agents/skills/spectra-ask/SKILL.md
  - .remember/logs/autonomous/save-002847.log
  - .remember/logs/autonomous/save-001309.log
  - .remember/logs/autonomous/save-002345.log
  - .remember/logs/autonomous/save-001425.log
  - .remember/logs/autonomous/save-053406.log
  - .remember/logs/autonomous/save-001555.log
  - .remember/logs/autonomous/save-001418.log
  - .remember/logs/autonomous/save-002232.log
  - .remember/logs/autonomous/save-001455.log
  - .remember/logs/autonomous/save-001834.log
  - Tests/MailSQLiteTests/MailboxURLTests.swift
  - .remember/logs/autonomous/save-001432.log
  - .remember/logs/autonomous/save-053728.log
  - .remember/logs/autonomous/save-005259.log
  - .remember/logs/autonomous/save-001901.log
  - .remember/logs/autonomous/save-001543.log
  - .remember/logs/autonomous/save-001304.log
  - .remember/logs/autonomous/save-002244.log
  - .remember/logs/autonomous/save-053218.log
  - .remember/logs/autonomous/save-053433.log
  - .remember/logs/autonomous/save-054753.log
  - Sources/MailSQLite/RFC822Parser.swift
  - .remember/logs/autonomous/save-053416.log
  - .remember/logs/autonomous/save-003428.log
  - .remember/logs/autonomous/save-053341.log
  - .remember/logs/autonomous/save-000627.log
  - .remember/logs/autonomous/save-002359.log
  - .remember/logs/autonomous/save-002229.log
  - .remember/logs/autonomous/save-053445.log
  - Sources/MailSQLite/SearchResult.swift
  - .remember/logs/autonomous/save-005355.log
  - .remember/logs/autonomous/save-003351.log
  - .remember/logs/autonomous/save-001029.log
  - Tests/MailSQLiteTests/EmailContentTests.swift
  - .remember/logs/autonomous/save-000614.log
  - .remember/logs/autonomous/save-002046.log
  - .remember/logs/autonomous/save-002713.log
  - .remember/logs/autonomous/save-001534.log
  - .remember/logs/autonomous/save-053517.log
  - Tests/MailSQLiteTests/HeaderParserTests.swift
  - .remember/logs/autonomous/save-001520.log
  - .remember/logs/autonomous/save-002612.log
  - .remember/logs/autonomous/save-003306.log
  - .remember/logs/autonomous/save-053441.log
  - .remember/logs/autonomous/save-001622.log
  - .remember/logs/autonomous/save-000601.log
  - .remember/logs/autonomous/save-001311.log
  - .remember/logs/autonomous/save-053736.log
  - .remember/logs/autonomous/save-001725.log
  - Tests/MailSQLiteTests/BatchOperationTests.swift
  - .remember/logs/autonomous/save-053259.log
  - .remember/logs/autonomous/save-053332.log
  - .remember/logs/autonomous/save-001804.log
  - .remember/logs/autonomous/save-001337.log
  - .remember/logs/autonomous/save-054754.log
  - .remember/logs/autonomous/save-053415.log
  - .remember/logs/autonomous/save-053457.log
  - .remember/logs/autonomous/save-000442.log
  - .remember/logs/autonomous/save-003252.log
  - .remember/logs/autonomous/save-002558.log
  - .remember/logs/autonomous/save-053715.log
  - .remember/logs/autonomous/save-005655.log
  - .remember/logs/autonomous/save-003502.log
  - .remember/logs/autonomous/save-002645.log
  - .remember/logs/autonomous/save-000528.log
  - Sources/MailSQLite/MailSQLiteError.swift
  - .remember/logs/autonomous/save-002400.log
  - .remember/logs/autonomous/save-001315.log
  - .remember/logs/autonomous/save-005635.log
  - .remember/logs/autonomous/save-002003.log
  - .remember/logs/autonomous/save-053512.log
  - .remember/logs/autonomous/save-003407.log
  - .remember/logs/autonomous/save-002235.log
  - .remember/logs/autonomous/save-002941.log
  - .remember/logs/autonomous/save-001451.log
  - .remember/logs/autonomous/save-053550.log
  - .remember/logs/autonomous/save-001828.log
  - .remember/logs/autonomous/save-000536.log
  - .remember/logs/autonomous/save-000602.log
  - Sources/MailSQLite/BatchValidator.swift
  - .remember/logs/autonomous/save-053409.log
  - .remember/logs/autonomous/save-005354.log
  - .remember/logs/autonomous/save-002420.log
  - .remember/logs/autonomous/save-053354.log
  - .remember/logs/autonomous/save-053157.log
  - Tests/MailSQLiteTests/EmlxPathTests.swift
  - .remember/logs/autonomous/save-053249.log
  - .remember/logs/autonomous/save-005601.log
  - Sources/CheAppleMailMCP/Server.swift
  - .remember/logs/autonomous/save-053350.log
  - .remember/logs/autonomous/save-000429.log
  - .agents/skills/spectra-propose/SKILL.md
  - .remember/logs/autonomous/save-002658.log
  - .remember/logs/autonomous/save-053355.log
  - .agents/skills/spectra-archive/SKILL.md
  - .remember/logs/autonomous/save-003020.log
  - .remember/logs/autonomous/save-001908.log
  - .remember/logs/autonomous/save-000834.log
  - .remember/logs/autonomous/save-053611.log
  - .remember/logs/autonomous/save-002228.log
  - .remember/logs/autonomous/save-002039.log
  - .remember/logs/autonomous/save-053338.log
  - .remember/logs/autonomous/save-002118.log
  - .remember/logs/autonomous/save-001019.log
  - .agents/skills/spectra-apply/SKILL.md
  - Tests/MailSQLiteTests/FallbackTests.swift
  - .remember/logs/autonomous/save-000420.log
  - .remember/logs/autonomous/save-002030.log
  - .remember/logs/autonomous/save-053424.log
  - .remember/logs/autonomous/save-000427.log
  - Sources/MailSQLite/EmlxFormat.swift
  - .remember/logs/autonomous/save-001627.log
  - .remember/logs/autonomous/save-001928.log
  - .remember/logs/autonomous/save-005252.log
  - Tests/MailSQLiteTests/BatchEmptyTests.swift
  - .remember/logs/autonomous/save-001001.log
  - Tests/MailSQLiteTests/SearchIntegrationTests.swift
  - .remember/logs/autonomous/save-053220.log
  - .remember/logs/autonomous/save-001024.log
  - .remember/logs/autonomous/save-001119.log
  - .remember/logs/autonomous/save-002620.log
  - .remember/logs/autonomous/save-003509.log
  - .agents/skills/spectra-debug/SKILL.md
  - .remember/logs/autonomous/save-001921.log
  - .remember/logs/autonomous/save-053650.log
  - Sources/MailSQLite/MIMEParser.swift
  - .remember/logs/autonomous/save-003455.log
  - .remember/logs/autonomous/save-003102.log
  - .remember/logs/autonomous/save-053700.log
  - .remember/logs/autonomous/save-053422.log
  - AGENTS.md
  - .remember/logs/autonomous/save-002706.log
  - Tests/MailSQLiteTests/EnvelopeIndexReaderTests.swift
  - .remember/logs/autonomous/save-000458.log
  - .remember/logs/autonomous/save-054747.log
  - .remember/logs/autonomous/save-001234.log
  - .remember/logs/autonomous/save-000547.log
  - .remember/logs/autonomous/save-005611.log
  - .remember/logs/autonomous/save-005626.log
  - Sources/CheAppleMailMCP/AppleScript/MailController.swift
  - Sources/MailSQLite/MailboxURL.swift
  - .remember/logs/autonomous/save-003313.log
  - .remember/logs/autonomous/save-001159.log
  - .remember/logs/autonomous/save-000923.log
  - .remember/logs/autonomous/save-003120.log
  - .remember/logs/autonomous/save-001414.log
  - .remember/logs/autonomous/save-053404.log
  - .remember/logs/autonomous/save-001352.log
  - .remember/logs/autonomous/save-000508.log
  - .remember/logs/autonomous/save-001655.log
  - .remember/logs/autonomous/save-002300.log
  - .remember/logs/autonomous/save-000409.log
  - .remember/logs/autonomous/save-000705.log
  - .remember/logs/autonomous/save-001732.log
  - .remember/logs/autonomous/save-002447.log
  - .remember/logs/autonomous/save-003524.log
  - .remember/logs/autonomous/save-003445.log
  - .remember/logs/autonomous/save-001747.log
  - .remember/logs/autonomous/save-053401.log
  - .remember/logs/autonomous/save-000535.log
  - .remember/logs/autonomous/save-000634.log
  - .remember/logs/autonomous/save-003335.log
  - Tests/MailSQLiteTests/BatchPartialFailureTests.swift
  - .remember/logs/autonomous/save-002414.log
  - .remember/logs/autonomous/save-002133.log
  - .remember/logs/autonomous/save-001133.log
  - .remember/logs/autonomous/save-000434.log
  - .remember/logs/autonomous/save-053234.log
  - .remember/logs/autonomous/save-053426.log
  - .remember/logs/autonomous/save-001550.log
  - .remember/logs/autonomous/save-002426.log
  - .remember/logs/autonomous/save-000613.log
  - .remember/logs/autonomous/save-002152.log
  - .remember/logs/autonomous/save-002737.log
  - .remember/logs/autonomous/save-053707.log
  - .remember/logs/autonomous/save-001336.log
  - .remember/logs/autonomous/save-005400.log
  - CLAUDE.md
  - .remember/logs/autonomous/save-000410.log
  - .remember/logs/autonomous/save-000527.log
  - .remember/logs/autonomous/save-001218.log
  - .remember/logs/autonomous/save-001223.log
  - .remember/logs/autonomous/save-001847.log
  - .remember/logs/autonomous/save-001755.log
  - .remember/logs/autonomous/save-000545.log
  - .remember/logs/autonomous/save-002729.log
  - .remember/logs/autonomous/save-002322.log
  - .remember/logs/autonomous/save-003010.log
  - .remember/logs/autonomous/save-002125.log
  - .remember/logs/autonomous/save-002224.log
  - .remember/logs/autonomous/save-053434.log
  - Package.swift
  - .remember/logs/autonomous/save-001812.log
  - Sources/MailSQLite/EmlxParser.swift
  - .remember/logs/autonomous/save-002933.log
  - .remember/logs/autonomous/save-000440.log
  - .remember/logs/autonomous/save-005711.log
  - .remember/logs/autonomous/save-003247.log
  - .remember/logs/autonomous/save-000459.log
  - .remember/logs/autonomous/save-000518.log
  - .remember/logs/autonomous/save-001508.log
  - .remember/logs/autonomous/save-003038.log
  - .remember/logs/autonomous/save-002249.log
  - .remember/logs/autonomous/save-002522.log
  - .remember/logs/autonomous/save-053356.log
  - .remember/logs/autonomous/save-001610.log
  - .remember/logs/autonomous/save-001212.log
  - .remember/logs/autonomous/save-001949.log
  - .remember/logs/autonomous/save-002951.log
  - .remember/logs/autonomous/save-053410.log
  - .remember/logs/autonomous/save-002334.log
  - .remember/logs/autonomous/save-002830.log
  - .remember/logs/autonomous/save-002256.log
  - .remember/logs/autonomous/save-005610.log
  - .remember/logs/autonomous/save-003532.log
  - .remember/logs/autonomous/save-001853.log
  - .remember/logs/autonomous/save-001603.log
  - .remember/logs/autonomous/save-000652.log
  - .remember/logs/autonomous/save-054739.log
  - .remember/logs/autonomous/save-053400.log
  - .remember/logs/autonomous/save-003045.log
  - .remember/logs/autonomous/save-005705.log
  - .remember/logs/autonomous/save-002914.log
  - .remember/logs/autonomous/save-053331.log
  - .remember/logs/autonomous/save-053208.log
  - Sources/MailSQLite/EmailContent.swift
  - .remember/logs/autonomous/save-002408.log
  - .agents/skills/spectra-audit/SKILL.md
  - Sources/MailSQLite/EnvelopeIndexReader.swift
  - .remember/logs/autonomous/save-002501.log
  - .remember/logs/autonomous/save-053357.log
  - .remember/logs/autonomous/save-053557.log
  - .remember/logs/autonomous/save-001636.log
  - Tests/MailSQLiteTests/MIMEParserTests.swift
  - .remember/logs/autonomous/save-000841.log
  - .remember/logs/autonomous/save-003109.log
  - .spectra.yaml
  - .remember/logs/autonomous/save-000456.log
  - .remember/logs/autonomous/save-000510.log
  - .remember/logs/autonomous/save-053639.log
  - .remember/logs/autonomous/save-001205.log
  - .remember/logs/autonomous/save-001320.log
  - .remember/logs/autonomous/save-001151.log
  - .remember/logs/autonomous/save-001709.log
  - .remember/logs/autonomous/save-002837.log
  - .agents/skills/spectra-discuss/SKILL.md
-->

---
### Requirement: Batch list attachments tool

The system SHALL provide a `list_attachments_batch` MCP tool that accepts an array of email identifiers and returns the attachment list for each email. Since attachment metadata requires AppleScript (`save attachment` paths are managed by Mail.app), this tool SHALL use the existing AppleScript-based `listAttachments` method for each email.

#### Scenario: Batch list attachments

- **WHEN** `list_attachments_batch` is called with `emails: [{"id": "100", "mailbox": "INBOX", "account_name": "Gmail"}, {"id": "200", "mailbox": "Sent", "account_name": "Gmail"}]`
- **THEN** the system returns an array where each entry contains the email identifier and its list of attachments (name, size, MIME type), each attachment additionally carrying the `savable` flag per the `sqlite-query-engine` `list_attachments` contract (present when the per-message `.emlx` is parseable, omitted otherwise)

#### Scenario: Batch list with email having no attachments

- **WHEN** an email in the batch has no attachments
- **THEN** the entry for that email contains an empty attachments array

#### Scenario: Batch list with partial failures

- **WHEN** one email in the batch cannot be found via AppleScript
- **THEN** the system returns results for successful emails and an error entry for the failed email, without aborting the entire batch


<!-- @trace
source: sqlite-search-engine
updated: 2026-04-01
code:
  - .remember/logs/autonomous/save-000640.log
  - .remember/logs/autonomous/save-053348.log
  - .remember/logs/autonomous/save-002310.log
  - .remember/logs/autonomous/save-002351.log
  - .remember/logs/autonomous/save-001649.log
  - .remember/logs/autonomous/save-053413.log
  - .remember/logs/autonomous/save-002438.log
  - .remember/logs/autonomous/save-053450.log
  - .remember/logs/autonomous/save-002236.log
  - .remember/logs/autonomous/save-053342.log
  - .remember/tmp/save-session.pid
  - .remember/logs/autonomous/save-000421.log
  - .remember/logs/autonomous/save-000520.log
  - Tests/MailSQLiteTests/EmlxFormatTests.swift
  - .remember/logs/autonomous/save-053405.log
  - .agents/skills/spectra-ingest/SKILL.md
  - .remember/logs/autonomous/save-053523.log
  - logs/mcptools/debug/debug-report-20260316-001500.md
  - .remember/logs/autonomous/save-001229.log
  - Tests/MailSQLiteTests/SearchTests.swift
  - .remember/logs/autonomous/save-002340.log
  - .remember/logs/autonomous/save-001250.log
  - .remember/logs/autonomous/save-002328.log
  - .remember/logs/autonomous/save-003320.log
  - .remember/logs/autonomous/save-003259.log
  - .remember/logs/autonomous/save-001939.log
  - .remember/logs/autonomous/save-001502.log
  - .agents/skills/spectra-ask/SKILL.md
  - .remember/logs/autonomous/save-002847.log
  - .remember/logs/autonomous/save-001309.log
  - .remember/logs/autonomous/save-002345.log
  - .remember/logs/autonomous/save-001425.log
  - .remember/logs/autonomous/save-053406.log
  - .remember/logs/autonomous/save-001555.log
  - .remember/logs/autonomous/save-001418.log
  - .remember/logs/autonomous/save-002232.log
  - .remember/logs/autonomous/save-001455.log
  - .remember/logs/autonomous/save-001834.log
  - Tests/MailSQLiteTests/MailboxURLTests.swift
  - .remember/logs/autonomous/save-001432.log
  - .remember/logs/autonomous/save-053728.log
  - .remember/logs/autonomous/save-005259.log
  - .remember/logs/autonomous/save-001901.log
  - .remember/logs/autonomous/save-001543.log
  - .remember/logs/autonomous/save-001304.log
  - .remember/logs/autonomous/save-002244.log
  - .remember/logs/autonomous/save-053218.log
  - .remember/logs/autonomous/save-053433.log
  - .remember/logs/autonomous/save-054753.log
  - Sources/MailSQLite/RFC822Parser.swift
  - .remember/logs/autonomous/save-053416.log
  - .remember/logs/autonomous/save-003428.log
  - .remember/logs/autonomous/save-053341.log
  - .remember/logs/autonomous/save-000627.log
  - .remember/logs/autonomous/save-002359.log
  - .remember/logs/autonomous/save-002229.log
  - .remember/logs/autonomous/save-053445.log
  - Sources/MailSQLite/SearchResult.swift
  - .remember/logs/autonomous/save-005355.log
  - .remember/logs/autonomous/save-003351.log
  - .remember/logs/autonomous/save-001029.log
  - Tests/MailSQLiteTests/EmailContentTests.swift
  - .remember/logs/autonomous/save-000614.log
  - .remember/logs/autonomous/save-002046.log
  - .remember/logs/autonomous/save-002713.log
  - .remember/logs/autonomous/save-001534.log
  - .remember/logs/autonomous/save-053517.log
  - Tests/MailSQLiteTests/HeaderParserTests.swift
  - .remember/logs/autonomous/save-001520.log
  - .remember/logs/autonomous/save-002612.log
  - .remember/logs/autonomous/save-003306.log
  - .remember/logs/autonomous/save-053441.log
  - .remember/logs/autonomous/save-001622.log
  - .remember/logs/autonomous/save-000601.log
  - .remember/logs/autonomous/save-001311.log
  - .remember/logs/autonomous/save-053736.log
  - .remember/logs/autonomous/save-001725.log
  - Tests/MailSQLiteTests/BatchOperationTests.swift
  - .remember/logs/autonomous/save-053259.log
  - .remember/logs/autonomous/save-053332.log
  - .remember/logs/autonomous/save-001804.log
  - .remember/logs/autonomous/save-001337.log
  - .remember/logs/autonomous/save-054754.log
  - .remember/logs/autonomous/save-053415.log
  - .remember/logs/autonomous/save-053457.log
  - .remember/logs/autonomous/save-000442.log
  - .remember/logs/autonomous/save-003252.log
  - .remember/logs/autonomous/save-002558.log
  - .remember/logs/autonomous/save-053715.log
  - .remember/logs/autonomous/save-005655.log
  - .remember/logs/autonomous/save-003502.log
  - .remember/logs/autonomous/save-002645.log
  - .remember/logs/autonomous/save-000528.log
  - Sources/MailSQLite/MailSQLiteError.swift
  - .remember/logs/autonomous/save-002400.log
  - .remember/logs/autonomous/save-001315.log
  - .remember/logs/autonomous/save-005635.log
  - .remember/logs/autonomous/save-002003.log
  - .remember/logs/autonomous/save-053512.log
  - .remember/logs/autonomous/save-003407.log
  - .remember/logs/autonomous/save-002235.log
  - .remember/logs/autonomous/save-002941.log
  - .remember/logs/autonomous/save-001451.log
  - .remember/logs/autonomous/save-053550.log
  - .remember/logs/autonomous/save-001828.log
  - .remember/logs/autonomous/save-000536.log
  - .remember/logs/autonomous/save-000602.log
  - Sources/MailSQLite/BatchValidator.swift
  - .remember/logs/autonomous/save-053409.log
  - .remember/logs/autonomous/save-005354.log
  - .remember/logs/autonomous/save-002420.log
  - .remember/logs/autonomous/save-053354.log
  - .remember/logs/autonomous/save-053157.log
  - Tests/MailSQLiteTests/EmlxPathTests.swift
  - .remember/logs/autonomous/save-053249.log
  - .remember/logs/autonomous/save-005601.log
  - Sources/CheAppleMailMCP/Server.swift
  - .remember/logs/autonomous/save-053350.log
  - .remember/logs/autonomous/save-000429.log
  - .agents/skills/spectra-propose/SKILL.md
  - .remember/logs/autonomous/save-002658.log
  - .remember/logs/autonomous/save-053355.log
  - .agents/skills/spectra-archive/SKILL.md
  - .remember/logs/autonomous/save-003020.log
  - .remember/logs/autonomous/save-001908.log
  - .remember/logs/autonomous/save-000834.log
  - .remember/logs/autonomous/save-053611.log
  - .remember/logs/autonomous/save-002228.log
  - .remember/logs/autonomous/save-002039.log
  - .remember/logs/autonomous/save-053338.log
  - .remember/logs/autonomous/save-002118.log
  - .remember/logs/autonomous/save-001019.log
  - .agents/skills/spectra-apply/SKILL.md
  - Tests/MailSQLiteTests/FallbackTests.swift
  - .remember/logs/autonomous/save-000420.log
  - .remember/logs/autonomous/save-002030.log
  - .remember/logs/autonomous/save-053424.log
  - .remember/logs/autonomous/save-000427.log
  - Sources/MailSQLite/EmlxFormat.swift
  - .remember/logs/autonomous/save-001627.log
  - .remember/logs/autonomous/save-001928.log
  - .remember/logs/autonomous/save-005252.log
  - Tests/MailSQLiteTests/BatchEmptyTests.swift
  - .remember/logs/autonomous/save-001001.log
  - Tests/MailSQLiteTests/SearchIntegrationTests.swift
  - .remember/logs/autonomous/save-053220.log
  - .remember/logs/autonomous/save-001024.log
  - .remember/logs/autonomous/save-001119.log
  - .remember/logs/autonomous/save-002620.log
  - .remember/logs/autonomous/save-003509.log
  - .agents/skills/spectra-debug/SKILL.md
  - .remember/logs/autonomous/save-001921.log
  - .remember/logs/autonomous/save-053650.log
  - Sources/MailSQLite/MIMEParser.swift
  - .remember/logs/autonomous/save-003455.log
  - .remember/logs/autonomous/save-003102.log
  - .remember/logs/autonomous/save-053700.log
  - .remember/logs/autonomous/save-053422.log
  - AGENTS.md
  - .remember/logs/autonomous/save-002706.log
  - Tests/MailSQLiteTests/EnvelopeIndexReaderTests.swift
  - .remember/logs/autonomous/save-000458.log
  - .remember/logs/autonomous/save-054747.log
  - .remember/logs/autonomous/save-001234.log
  - .remember/logs/autonomous/save-000547.log
  - .remember/logs/autonomous/save-005611.log
  - .remember/logs/autonomous/save-005626.log
  - Sources/CheAppleMailMCP/AppleScript/MailController.swift
  - Sources/MailSQLite/MailboxURL.swift
  - .remember/logs/autonomous/save-003313.log
  - .remember/logs/autonomous/save-001159.log
  - .remember/logs/autonomous/save-000923.log
  - .remember/logs/autonomous/save-003120.log
  - .remember/logs/autonomous/save-001414.log
  - .remember/logs/autonomous/save-053404.log
  - .remember/logs/autonomous/save-001352.log
  - .remember/logs/autonomous/save-000508.log
  - .remember/logs/autonomous/save-001655.log
  - .remember/logs/autonomous/save-002300.log
  - .remember/logs/autonomous/save-000409.log
  - .remember/logs/autonomous/save-000705.log
  - .remember/logs/autonomous/save-001732.log
  - .remember/logs/autonomous/save-002447.log
  - .remember/logs/autonomous/save-003524.log
  - .remember/logs/autonomous/save-003445.log
  - .remember/logs/autonomous/save-001747.log
  - .remember/logs/autonomous/save-053401.log
  - .remember/logs/autonomous/save-000535.log
  - .remember/logs/autonomous/save-000634.log
  - .remember/logs/autonomous/save-003335.log
  - Tests/MailSQLiteTests/BatchPartialFailureTests.swift
  - .remember/logs/autonomous/save-002414.log
  - .remember/logs/autonomous/save-002133.log
  - .remember/logs/autonomous/save-001133.log
  - .remember/logs/autonomous/save-000434.log
  - .remember/logs/autonomous/save-053234.log
  - .remember/logs/autonomous/save-053426.log
  - .remember/logs/autonomous/save-001550.log
  - .remember/logs/autonomous/save-002426.log
  - .remember/logs/autonomous/save-000613.log
  - .remember/logs/autonomous/save-002152.log
  - .remember/logs/autonomous/save-002737.log
  - .remember/logs/autonomous/save-053707.log
  - .remember/logs/autonomous/save-001336.log
  - .remember/logs/autonomous/save-005400.log
  - CLAUDE.md
  - .remember/logs/autonomous/save-000410.log
  - .remember/logs/autonomous/save-000527.log
  - .remember/logs/autonomous/save-001218.log
  - .remember/logs/autonomous/save-001223.log
  - .remember/logs/autonomous/save-001847.log
  - .remember/logs/autonomous/save-001755.log
  - .remember/logs/autonomous/save-000545.log
  - .remember/logs/autonomous/save-002729.log
  - .remember/logs/autonomous/save-002322.log
  - .remember/logs/autonomous/save-003010.log
  - .remember/logs/autonomous/save-002125.log
  - .remember/logs/autonomous/save-002224.log
  - .remember/logs/autonomous/save-053434.log
  - Package.swift
  - .remember/logs/autonomous/save-001812.log
  - Sources/MailSQLite/EmlxParser.swift
  - .remember/logs/autonomous/save-002933.log
  - .remember/logs/autonomous/save-000440.log
  - .remember/logs/autonomous/save-005711.log
  - .remember/logs/autonomous/save-003247.log
  - .remember/logs/autonomous/save-000459.log
  - .remember/logs/autonomous/save-000518.log
  - .remember/logs/autonomous/save-001508.log
  - .remember/logs/autonomous/save-003038.log
  - .remember/logs/autonomous/save-002249.log
  - .remember/logs/autonomous/save-002522.log
  - .remember/logs/autonomous/save-053356.log
  - .remember/logs/autonomous/save-001610.log
  - .remember/logs/autonomous/save-001212.log
  - .remember/logs/autonomous/save-001949.log
  - .remember/logs/autonomous/save-002951.log
  - .remember/logs/autonomous/save-053410.log
  - .remember/logs/autonomous/save-002334.log
  - .remember/logs/autonomous/save-002830.log
  - .remember/logs/autonomous/save-002256.log
  - .remember/logs/autonomous/save-005610.log
  - .remember/logs/autonomous/save-003532.log
  - .remember/logs/autonomous/save-001853.log
  - .remember/logs/autonomous/save-001603.log
  - .remember/logs/autonomous/save-000652.log
  - .remember/logs/autonomous/save-054739.log
  - .remember/logs/autonomous/save-053400.log
  - .remember/logs/autonomous/save-003045.log
  - .remember/logs/autonomous/save-005705.log
  - .remember/logs/autonomous/save-002914.log
  - .remember/logs/autonomous/save-053331.log
  - .remember/logs/autonomous/save-053208.log
  - Sources/MailSQLite/EmailContent.swift
  - .remember/logs/autonomous/save-002408.log
  - .agents/skills/spectra-audit/SKILL.md
  - Sources/MailSQLite/EnvelopeIndexReader.swift
  - .remember/logs/autonomous/save-002501.log
  - .remember/logs/autonomous/save-053357.log
  - .remember/logs/autonomous/save-053557.log
  - .remember/logs/autonomous/save-001636.log
  - Tests/MailSQLiteTests/MIMEParserTests.swift
  - .remember/logs/autonomous/save-000841.log
  - .remember/logs/autonomous/save-003109.log
  - .spectra.yaml
  - .remember/logs/autonomous/save-000456.log
  - .remember/logs/autonomous/save-000510.log
  - .remember/logs/autonomous/save-053639.log
  - .remember/logs/autonomous/save-001205.log
  - .remember/logs/autonomous/save-001320.log
  - .remember/logs/autonomous/save-001151.log
  - .remember/logs/autonomous/save-001709.log
  - .remember/logs/autonomous/save-002837.log
  - .agents/skills/spectra-discuss/SKILL.md
-->

---
### Requirement: Batch operation size limit

The system SHALL enforce a maximum batch size of 50 items per request for both `get_emails_batch` and `list_attachments_batch`. If the batch exceeds 50 items, the system SHALL return an error indicating the maximum batch size.

#### Scenario: Batch size within limit

- **WHEN** `get_emails_batch` is called with 30 email identifiers
- **THEN** the system processes all 30 emails normally

#### Scenario: Batch size exceeds limit

- **WHEN** `get_emails_batch` is called with 51 email identifiers
- **THEN** the system returns an error: "Batch size exceeds maximum of 50 items"

<!-- @trace
source: sqlite-search-engine
updated: 2026-04-01
code:
  - .remember/logs/autonomous/save-000640.log
  - .remember/logs/autonomous/save-053348.log
  - .remember/logs/autonomous/save-002310.log
  - .remember/logs/autonomous/save-002351.log
  - .remember/logs/autonomous/save-001649.log
  - .remember/logs/autonomous/save-053413.log
  - .remember/logs/autonomous/save-002438.log
  - .remember/logs/autonomous/save-053450.log
  - .remember/logs/autonomous/save-002236.log
  - .remember/logs/autonomous/save-053342.log
  - .remember/tmp/save-session.pid
  - .remember/logs/autonomous/save-000421.log
  - .remember/logs/autonomous/save-000520.log
  - Tests/MailSQLiteTests/EmlxFormatTests.swift
  - .remember/logs/autonomous/save-053405.log
  - .agents/skills/spectra-ingest/SKILL.md
  - .remember/logs/autonomous/save-053523.log
  - logs/mcptools/debug/debug-report-20260316-001500.md
  - .remember/logs/autonomous/save-001229.log
  - Tests/MailSQLiteTests/SearchTests.swift
  - .remember/logs/autonomous/save-002340.log
  - .remember/logs/autonomous/save-001250.log
  - .remember/logs/autonomous/save-002328.log
  - .remember/logs/autonomous/save-003320.log
  - .remember/logs/autonomous/save-003259.log
  - .remember/logs/autonomous/save-001939.log
  - .remember/logs/autonomous/save-001502.log
  - .agents/skills/spectra-ask/SKILL.md
  - .remember/logs/autonomous/save-002847.log
  - .remember/logs/autonomous/save-001309.log
  - .remember/logs/autonomous/save-002345.log
  - .remember/logs/autonomous/save-001425.log
  - .remember/logs/autonomous/save-053406.log
  - .remember/logs/autonomous/save-001555.log
  - .remember/logs/autonomous/save-001418.log
  - .remember/logs/autonomous/save-002232.log
  - .remember/logs/autonomous/save-001455.log
  - .remember/logs/autonomous/save-001834.log
  - Tests/MailSQLiteTests/MailboxURLTests.swift
  - .remember/logs/autonomous/save-001432.log
  - .remember/logs/autonomous/save-053728.log
  - .remember/logs/autonomous/save-005259.log
  - .remember/logs/autonomous/save-001901.log
  - .remember/logs/autonomous/save-001543.log
  - .remember/logs/autonomous/save-001304.log
  - .remember/logs/autonomous/save-002244.log
  - .remember/logs/autonomous/save-053218.log
  - .remember/logs/autonomous/save-053433.log
  - .remember/logs/autonomous/save-054753.log
  - Sources/MailSQLite/RFC822Parser.swift
  - .remember/logs/autonomous/save-053416.log
  - .remember/logs/autonomous/save-003428.log
  - .remember/logs/autonomous/save-053341.log
  - .remember/logs/autonomous/save-000627.log
  - .remember/logs/autonomous/save-002359.log
  - .remember/logs/autonomous/save-002229.log
  - .remember/logs/autonomous/save-053445.log
  - Sources/MailSQLite/SearchResult.swift
  - .remember/logs/autonomous/save-005355.log
  - .remember/logs/autonomous/save-003351.log
  - .remember/logs/autonomous/save-001029.log
  - Tests/MailSQLiteTests/EmailContentTests.swift
  - .remember/logs/autonomous/save-000614.log
  - .remember/logs/autonomous/save-002046.log
  - .remember/logs/autonomous/save-002713.log
  - .remember/logs/autonomous/save-001534.log
  - .remember/logs/autonomous/save-053517.log
  - Tests/MailSQLiteTests/HeaderParserTests.swift
  - .remember/logs/autonomous/save-001520.log
  - .remember/logs/autonomous/save-002612.log
  - .remember/logs/autonomous/save-003306.log
  - .remember/logs/autonomous/save-053441.log
  - .remember/logs/autonomous/save-001622.log
  - .remember/logs/autonomous/save-000601.log
  - .remember/logs/autonomous/save-001311.log
  - .remember/logs/autonomous/save-053736.log
  - .remember/logs/autonomous/save-001725.log
  - Tests/MailSQLiteTests/BatchOperationTests.swift
  - .remember/logs/autonomous/save-053259.log
  - .remember/logs/autonomous/save-053332.log
  - .remember/logs/autonomous/save-001804.log
  - .remember/logs/autonomous/save-001337.log
  - .remember/logs/autonomous/save-054754.log
  - .remember/logs/autonomous/save-053415.log
  - .remember/logs/autonomous/save-053457.log
  - .remember/logs/autonomous/save-000442.log
  - .remember/logs/autonomous/save-003252.log
  - .remember/logs/autonomous/save-002558.log
  - .remember/logs/autonomous/save-053715.log
  - .remember/logs/autonomous/save-005655.log
  - .remember/logs/autonomous/save-003502.log
  - .remember/logs/autonomous/save-002645.log
  - .remember/logs/autonomous/save-000528.log
  - Sources/MailSQLite/MailSQLiteError.swift
  - .remember/logs/autonomous/save-002400.log
  - .remember/logs/autonomous/save-001315.log
  - .remember/logs/autonomous/save-005635.log
  - .remember/logs/autonomous/save-002003.log
  - .remember/logs/autonomous/save-053512.log
  - .remember/logs/autonomous/save-003407.log
  - .remember/logs/autonomous/save-002235.log
  - .remember/logs/autonomous/save-002941.log
  - .remember/logs/autonomous/save-001451.log
  - .remember/logs/autonomous/save-053550.log
  - .remember/logs/autonomous/save-001828.log
  - .remember/logs/autonomous/save-000536.log
  - .remember/logs/autonomous/save-000602.log
  - Sources/MailSQLite/BatchValidator.swift
  - .remember/logs/autonomous/save-053409.log
  - .remember/logs/autonomous/save-005354.log
  - .remember/logs/autonomous/save-002420.log
  - .remember/logs/autonomous/save-053354.log
  - .remember/logs/autonomous/save-053157.log
  - Tests/MailSQLiteTests/EmlxPathTests.swift
  - .remember/logs/autonomous/save-053249.log
  - .remember/logs/autonomous/save-005601.log
  - Sources/CheAppleMailMCP/Server.swift
  - .remember/logs/autonomous/save-053350.log
  - .remember/logs/autonomous/save-000429.log
  - .agents/skills/spectra-propose/SKILL.md
  - .remember/logs/autonomous/save-002658.log
  - .remember/logs/autonomous/save-053355.log
  - .agents/skills/spectra-archive/SKILL.md
  - .remember/logs/autonomous/save-003020.log
  - .remember/logs/autonomous/save-001908.log
  - .remember/logs/autonomous/save-000834.log
  - .remember/logs/autonomous/save-053611.log
  - .remember/logs/autonomous/save-002228.log
  - .remember/logs/autonomous/save-002039.log
  - .remember/logs/autonomous/save-053338.log
  - .remember/logs/autonomous/save-002118.log
  - .remember/logs/autonomous/save-001019.log
  - .agents/skills/spectra-apply/SKILL.md
  - Tests/MailSQLiteTests/FallbackTests.swift
  - .remember/logs/autonomous/save-000420.log
  - .remember/logs/autonomous/save-002030.log
  - .remember/logs/autonomous/save-053424.log
  - .remember/logs/autonomous/save-000427.log
  - Sources/MailSQLite/EmlxFormat.swift
  - .remember/logs/autonomous/save-001627.log
  - .remember/logs/autonomous/save-001928.log
  - .remember/logs/autonomous/save-005252.log
  - Tests/MailSQLiteTests/BatchEmptyTests.swift
  - .remember/logs/autonomous/save-001001.log
  - Tests/MailSQLiteTests/SearchIntegrationTests.swift
  - .remember/logs/autonomous/save-053220.log
  - .remember/logs/autonomous/save-001024.log
  - .remember/logs/autonomous/save-001119.log
  - .remember/logs/autonomous/save-002620.log
  - .remember/logs/autonomous/save-003509.log
  - .agents/skills/spectra-debug/SKILL.md
  - .remember/logs/autonomous/save-001921.log
  - .remember/logs/autonomous/save-053650.log
  - Sources/MailSQLite/MIMEParser.swift
  - .remember/logs/autonomous/save-003455.log
  - .remember/logs/autonomous/save-003102.log
  - .remember/logs/autonomous/save-053700.log
  - .remember/logs/autonomous/save-053422.log
  - AGENTS.md
  - .remember/logs/autonomous/save-002706.log
  - Tests/MailSQLiteTests/EnvelopeIndexReaderTests.swift
  - .remember/logs/autonomous/save-000458.log
  - .remember/logs/autonomous/save-054747.log
  - .remember/logs/autonomous/save-001234.log
  - .remember/logs/autonomous/save-000547.log
  - .remember/logs/autonomous/save-005611.log
  - .remember/logs/autonomous/save-005626.log
  - Sources/CheAppleMailMCP/AppleScript/MailController.swift
  - Sources/MailSQLite/MailboxURL.swift
  - .remember/logs/autonomous/save-003313.log
  - .remember/logs/autonomous/save-001159.log
  - .remember/logs/autonomous/save-000923.log
  - .remember/logs/autonomous/save-003120.log
  - .remember/logs/autonomous/save-001414.log
  - .remember/logs/autonomous/save-053404.log
  - .remember/logs/autonomous/save-001352.log
  - .remember/logs/autonomous/save-000508.log
  - .remember/logs/autonomous/save-001655.log
  - .remember/logs/autonomous/save-002300.log
  - .remember/logs/autonomous/save-000409.log
  - .remember/logs/autonomous/save-000705.log
  - .remember/logs/autonomous/save-001732.log
  - .remember/logs/autonomous/save-002447.log
  - .remember/logs/autonomous/save-003524.log
  - .remember/logs/autonomous/save-003445.log
  - .remember/logs/autonomous/save-001747.log
  - .remember/logs/autonomous/save-053401.log
  - .remember/logs/autonomous/save-000535.log
  - .remember/logs/autonomous/save-000634.log
  - .remember/logs/autonomous/save-003335.log
  - Tests/MailSQLiteTests/BatchPartialFailureTests.swift
  - .remember/logs/autonomous/save-002414.log
  - .remember/logs/autonomous/save-002133.log
  - .remember/logs/autonomous/save-001133.log
  - .remember/logs/autonomous/save-000434.log
  - .remember/logs/autonomous/save-053234.log
  - .remember/logs/autonomous/save-053426.log
  - .remember/logs/autonomous/save-001550.log
  - .remember/logs/autonomous/save-002426.log
  - .remember/logs/autonomous/save-000613.log
  - .remember/logs/autonomous/save-002152.log
  - .remember/logs/autonomous/save-002737.log
  - .remember/logs/autonomous/save-053707.log
  - .remember/logs/autonomous/save-001336.log
  - .remember/logs/autonomous/save-005400.log
  - CLAUDE.md
  - .remember/logs/autonomous/save-000410.log
  - .remember/logs/autonomous/save-000527.log
  - .remember/logs/autonomous/save-001218.log
  - .remember/logs/autonomous/save-001223.log
  - .remember/logs/autonomous/save-001847.log
  - .remember/logs/autonomous/save-001755.log
  - .remember/logs/autonomous/save-000545.log
  - .remember/logs/autonomous/save-002729.log
  - .remember/logs/autonomous/save-002322.log
  - .remember/logs/autonomous/save-003010.log
  - .remember/logs/autonomous/save-002125.log
  - .remember/logs/autonomous/save-002224.log
  - .remember/logs/autonomous/save-053434.log
  - Package.swift
  - .remember/logs/autonomous/save-001812.log
  - Sources/MailSQLite/EmlxParser.swift
  - .remember/logs/autonomous/save-002933.log
  - .remember/logs/autonomous/save-000440.log
  - .remember/logs/autonomous/save-005711.log
  - .remember/logs/autonomous/save-003247.log
  - .remember/logs/autonomous/save-000459.log
  - .remember/logs/autonomous/save-000518.log
  - .remember/logs/autonomous/save-001508.log
  - .remember/logs/autonomous/save-003038.log
  - .remember/logs/autonomous/save-002249.log
  - .remember/logs/autonomous/save-002522.log
  - .remember/logs/autonomous/save-053356.log
  - .remember/logs/autonomous/save-001610.log
  - .remember/logs/autonomous/save-001212.log
  - .remember/logs/autonomous/save-001949.log
  - .remember/logs/autonomous/save-002951.log
  - .remember/logs/autonomous/save-053410.log
  - .remember/logs/autonomous/save-002334.log
  - .remember/logs/autonomous/save-002830.log
  - .remember/logs/autonomous/save-002256.log
  - .remember/logs/autonomous/save-005610.log
  - .remember/logs/autonomous/save-003532.log
  - .remember/logs/autonomous/save-001853.log
  - .remember/logs/autonomous/save-001603.log
  - .remember/logs/autonomous/save-000652.log
  - .remember/logs/autonomous/save-054739.log
  - .remember/logs/autonomous/save-053400.log
  - .remember/logs/autonomous/save-003045.log
  - .remember/logs/autonomous/save-005705.log
  - .remember/logs/autonomous/save-002914.log
  - .remember/logs/autonomous/save-053331.log
  - .remember/logs/autonomous/save-053208.log
  - Sources/MailSQLite/EmailContent.swift
  - .remember/logs/autonomous/save-002408.log
  - .agents/skills/spectra-audit/SKILL.md
  - Sources/MailSQLite/EnvelopeIndexReader.swift
  - .remember/logs/autonomous/save-002501.log
  - .remember/logs/autonomous/save-053357.log
  - .remember/logs/autonomous/save-053557.log
  - .remember/logs/autonomous/save-001636.log
  - Tests/MailSQLiteTests/MIMEParserTests.swift
  - .remember/logs/autonomous/save-000841.log
  - .remember/logs/autonomous/save-003109.log
  - .spectra.yaml
  - .remember/logs/autonomous/save-000456.log
  - .remember/logs/autonomous/save-000510.log
  - .remember/logs/autonomous/save-053639.log
  - .remember/logs/autonomous/save-001205.log
  - .remember/logs/autonomous/save-001320.log
  - .remember/logs/autonomous/save-001151.log
  - .remember/logs/autonomous/save-001709.log
  - .remember/logs/autonomous/save-002837.log
  - .agents/skills/spectra-discuss/SKILL.md
-->

---
### Requirement: Server-side markdown export

The system SHALL provide a server-side markdown export MCP tool under the canonical name `batch_export_emails_markdown` — with `export_emails_markdown` as a deprecated alias, per the "Batch export tool naming and deprecation alias" requirement below (scenario steps in this requirement that invoke `export_emails_markdown` apply equally under either name) — that, given a list of message ids, fetches each email's full content, renders it to a markdown file with a fixed frontmatter contract, optionally writes its attachments, and returns a per-email manifest — performing the entire email→markdown+attachments transcription server-side so callers do not transcribe email bodies themselves. The tool SHALL be additive: it MUST NOT change the input schema or behaviour of any existing tool, nor `MIMEParser.parseBody` / `ParsedEmailContent`.

The tool input SHALL accept `ids` (array), `mailbox`, `account_name`, `output_dir`, and an optional `opts` object with `include_attachments` (bool), `filename_template` (string), `filenames` (per-id map), and `extra_frontmatter` (object of static key/value pairs appended to every file's frontmatter after the six core fields).

Email bodies SHALL be fetched via the existing SQLite envelope index + `.emlx` read path (`EnvelopeIndexReader` / `EmlxParser`); the tool MUST NOT introduce new SQLite schema or DDL.

**Frontmatter contract (frozen).** Each rendered file SHALL begin with a YAML frontmatter block containing exactly these six core fields, in this order: `message_id` (RFC 5322 Message-ID, double-quoted), `thread_key` (the subject with leading reply/forward prefixes — `Re:` / `RE:` / `Fwd:` / `FW:` / `转发:` / `轉寄:` / `回覆:` / `回复:` — repeatedly stripped and trimmed), `in_reply_to` (the In-Reply-To Message-ID or empty), `date` (ISO 8601 preserving the original `Date` header's numeric UTC offset, e.g. `2026-07-13T16:49:57+08:00`; a zero offset renders as `Z`. An RFC 2822 obsolete trailing comment — e.g. `+0800 (CST)` / `+0000 (UTC)` — SHALL be ignored for parsing and offset extraction. When the header carries no numeric offset — a named zone or none — the value falls back to ISO 8601 in UTC; an unparseable date passes through flattened, as before), `sender` (bare email address, display name stripped), and `direction` (`received` or `sent`). `opts.extra_frontmatter` MAY add further fields but MUST NOT remove or reorder the six core fields. Frontmatter values SHALL be emitted so that no value (subject, message-id, sender, date, or any header) can inject a spurious frontmatter line — line breaks and control characters in a value SHALL be flattened. After the frontmatter, the file SHALL contain a plain `Subject` / `From` / `To` / `Cc` (omitted when there is no cc) / `Date` header block, then the **verbatim** message body with no summarization, paraphrase, or truncation.

**Output directory safety (allowed-roots).** Before writing any file, `output_dir` SHALL be validated: its canonical real path (with `..` and symlinks resolved) MUST lie within the user's home directory or one of the configured `export_allowed_roots` entries (each also resolved to a real path), otherwise the tool SHALL reject the entire call without writing any file. The tool SHALL additionally reject canonical paths under system directories (`/System`, `/usr`, `/bin`, `/sbin`, `/etc`, `/private/etc`, and `/Library` other than the user's `~/Library`) as a defence-in-depth denylist. Symlink escape SHALL be prevented by comparing real paths on both sides.

**Leaf-path containment.** Validating `output_dir` is necessary but not sufficient, because the per-file leaf names are independently attacker-influenced (the attachment name is sender-controlled MIME metadata; `filename_template` / per-id `filenames` are caller-controlled; an unparseable `Date` header would otherwise pass through into the default name). Therefore every leaf path the tool builds — the `.md` filename, the attachment destination directory, and each attachment file — SHALL be reduced to a single safe path segment (path separators and control characters rejected or collapsed; `.`/`..`/empty disallowed) AND SHALL be re-verified to canonicalize back inside `output_dir` (resolving symlinks, so a pre-planted symlink at an intermediate directory cannot redirect a write) before that file is written. A leaf that fails containment SHALL be skipped and recorded — never written outside `output_dir`.

**Filenames.** The default filename SHALL be `<YYYY-MM-DD>_<slug>.md`, where the date is the calendar date of the email's `Date` header in its original numeric UTC offset (sender-local; falling back to the UTC calendar date when no numeric offset is available, and to `unknown-date` when the Date header cannot be parsed at all — a raw passthrough never contributes a partial fragment to the filename) and the slug is the bare subject sanitized (whitespace and punctuation replaced with `-`, CJK/Unicode letters preserved, truncated to at most 50 grapheme clusters, leading/trailing `-` stripped, empty → `no-subject`). Within a single call, no two emails SHALL ever resolve to the same written path: files sharing a resolved name SHALL receive collision suffixes `-1`, `-2`, … This de-duplication SHALL apply uniformly to all three naming branches (default, `filename_template`, per-id `filenames`), so a template or override that maps two emails to one name SHALL still produce two distinct files rather than silently overwriting. `opts.filename_template` (supporting `{date}` / `{subject}` / `{sender}` / `{message_id}` placeholders) or a per-id `opts.filenames` entry SHALL override the default; overridden and templated names SHALL be reduced to a single sanitized path segment. The manifest SHALL always report the actual written path.

**Attachments.** When `opts.include_attachments` is true, each email's attachments SHALL be written using the existing `.emlx` attachment extraction path (`AttachmentExtractor`): document-class files to `output_dir/attachments/<stem>/` and data-class extensions (`csv`, `tsv`, `sav`, `dta`, `parquet`, `feather`, `xlsx`, `sas7bdat`, `rds`) to `output_dir/data/`, where `<stem>` is the markdown filename without `.md`. An attachment whose sender-controlled name is not a single safe path segment SHALL be rejected (not written). An `Attachments:` section listing the successfully-written files SHALL be appended to that email's markdown, and the paths SHALL be recorded in that email's manifest entry. An attachment-extraction or attachment-rejection failure SHALL NOT abort the email's markdown write, but SHALL be recorded in that email's manifest entry (never silently dropped). If the email's markdown write itself fails, any attachments already written for that email SHALL be removed so the failed item leaves no orphan files.

**Partial-failure manifest.** The tool SHALL process each id independently: a fetch, render, or write failure for one id SHALL be recorded as an error entry for that id and SHALL NOT abort the batch. The tool SHALL return a manifest object `{ output_dir, written, errors, items }` where each `items` entry is `{ message_id, written_path, attachments, attachment_errors?, status: "written" }` on success or `{ message_id?, status: "error", error }` on failure. The optional `attachment_errors` array SHALL record any per-attachment rejections or extraction failures for an otherwise-written email.

#### Scenario: Export a batch of emails to an allowed directory

- **WHEN** `export_emails_markdown` is called with three valid `ids`, a `mailbox`, an `account_name`, and an `output_dir` whose canonical path is under the user's home directory
- **THEN** three `.md` files SHALL be written under `output_dir`
- **AND** each file SHALL begin with a frontmatter block containing the six core fields (`message_id`, `thread_key`, `in_reply_to`, `date`, `sender`, `direction`) in order
- **AND** each file's body SHALL be the verbatim email body
- **AND** the returned manifest SHALL report `written: 3`, `errors: 0`, and three `status: "written"` items each with its actual `written_path`

#### Scenario: Reject output_dir that escapes the allowed roots

- **WHEN** `export_emails_markdown` is called with an `output_dir` whose canonical real path is `/etc` (or any path outside the home directory and configured allowed roots)
- **THEN** the tool SHALL reject the call with an `outputDirEscapesAllowedRoots` (or `outputDirIsSystemPath`) error
- **AND** no file SHALL be written

#### Scenario: Reject symlink escape

- **WHEN** `output_dir` is a path that resolves through a symlink to a location outside the allowed roots (e.g. a symlink under home pointing at `/private/etc`)
- **THEN** the canonical real-path comparison SHALL detect the escape and the tool SHALL reject the call without writing any file

#### Scenario: Export with attachments routes by class

- **WHEN** `export_emails_markdown` is called with `opts.include_attachments = true` and one of the emails has a `report.pdf` attachment and a `data.csv` attachment
- **THEN** `report.pdf` SHALL be written under `output_dir/attachments/<stem>/`
- **AND** `data.csv` SHALL be written under `output_dir/data/`
- **AND** that email's markdown SHALL contain an `Attachments:` section listing both
- **AND** that email's manifest entry `attachments` SHALL list both written paths

#### Scenario: Reject leaf-name path traversal

- **WHEN** `export_emails_markdown` is called with `opts.include_attachments = true` and an email whose attachment name is `../../escape.txt` (or a per-id `filenames` override of `../../evil`)
- **THEN** no file SHALL be written outside `output_dir`
- **AND** the email's markdown SHALL still be written inside `output_dir` with `status: "written"`
- **AND** the rejected attachment SHALL be recorded in that email's `attachment_errors` (the markdown filename SHALL be reduced to a safe segment inside `output_dir`)

#### Scenario: Template or override collision does not overwrite

- **WHEN** two requested emails resolve to the same `filename_template` result (or the same per-id `filenames` value)
- **THEN** two distinct `.md` files SHALL be written (the second receiving a `-1` suffix), not one silently overwriting the other
- **AND** the manifest SHALL report `written: 2` with two distinct `written_path`s

#### Scenario: Partial failure does not abort the batch

- **WHEN** `export_emails_markdown` is called with five `ids`, one of which refers to a message whose `.emlx` cannot be parsed
- **THEN** the four parseable emails SHALL be written to `output_dir`
- **AND** the manifest SHALL contain four `status: "written"` items and one `status: "error"` item with a non-empty `error`
- **AND** `written` SHALL be 4 and `errors` SHALL be 1

#### Scenario: Same-day same-subject filenames get collision suffixes

- **WHEN** two of the requested emails share the same Date day and the same bare subject
- **THEN** the first (by date order) SHALL be written as `<YYYY-MM-DD>_<slug>.md`
- **AND** the second SHALL be written as `<YYYY-MM-DD>_<slug>-1.md`
- **AND** both actual paths SHALL be reported in the manifest

#### Scenario: Frontmatter date preserves the original UTC offset

- **WHEN** an exported email's `Date` header is `Mon, 13 Jul 2026 16:49:57 +0800`
- **THEN** the frontmatter SHALL read `date: 2026-07-13T16:49:57+08:00` (same instant, original offset — consistent with the body `Date:` line)
- **AND** the default filename SHALL begin with `2026-07-13` (the sender-local calendar date)
- **AND** a header carrying an obsolete trailing comment (`Mon, 13 Jul 2026 16:49:57 +0800 (CST)`) SHALL parse identically — comment ignored, offset preserved
- **AND** an email whose `Date` header has a named or missing zone SHALL fall back to the previous ISO 8601 UTC (`Z`) rendering
- **AND** an email whose `Date` header cannot be parsed at all SHALL pass through flattened exactly as before (leaf-path containment unchanged)

#### Scenario: Existing tools are unchanged

- **WHEN** the change is applied
- **THEN** the input schema and behaviour of `get_email`, `get_emails_batch`, `list_attachments`, and `save_attachment` SHALL be unchanged
- **AND** `MIMEParser.parseBody` and `ParsedEmailContent` SHALL retain their existing signatures and behaviour

---
### Requirement: Batch get emails Message-ID parity

Each per-email result object returned by `get_emails_batch` SHALL include a `message_id` field carrying the resolved RFC 5322 Message-ID of that email, achieving parity with the single `get_email` tool (which already returns `message_id`). When the source email has no Message-ID header, the field SHALL be the empty string rather than absent. This is an additive field; no existing `get_emails_batch` result field is renamed or removed, and per-email `error` entries are unaffected.

#### Scenario: batch result carries message_id per email

- **WHEN** `get_emails_batch` is called for emails that each have a Message-ID header
- **THEN** each successful per-email result object includes a `message_id` field equal to that email's RFC 5322 Message-ID

#### Scenario: missing Message-ID yields empty string, not absence

- **WHEN** `get_emails_batch` processes an email whose source has no Message-ID header
- **THEN** that result object's `message_id` field is the empty string (the field is present)

---
### Requirement: Markdown export manifest carries Message-ID

Each item in the `export_emails_markdown` manifest SHALL include a `message_id` field carrying the resolved RFC 5322 Message-ID of the exported email (empty string when the source has none, mirroring the existing `in_reply_to` convention). This lets a caller reconcile a Message-ID-keyed archive index from the manifest alone, without re-fetching email content. The field is additive; the markdown/frontmatter/filename output format is unchanged.

#### Scenario: manifest item includes message_id

- **WHEN** `export_emails_markdown` writes an email that has a Message-ID
- **THEN** the corresponding manifest item includes a `message_id` field equal to that email's RFC 5322 Message-ID
- **AND** the written markdown file's format (frontmatter, filename) is unchanged from before this field was added

---
### Requirement: Markdown export Message-ID dedup skip-set

`export_emails_markdown` SHALL accept an optional `skip_message_ids_path` parameter: a filesystem path to a file listing already-archived RFC 5322 Message-IDs, one per line, where blank lines and lines beginning with `#` are ignored. When provided, for each candidate email whose resolved Message-ID is present in that set, the system SHALL **skip** writing the email and instead record it in the manifest as an item with `status: "skipped"` (including its `id` and `message_id`); the manifest summary SHALL include a `skipped` count alongside the existing `written` and `errors` counts. Email content of skipped (or written) emails SHALL NOT enter the tool's textual response — only the manifest summary is returned.

The `skip_message_ids_path` SHALL be validated under the same allowed-roots write-safety policy as `output_dir` (read access; reuse `AllowedRootsValidator`), and the file SHALL be parsed only as a Message-ID line list and never echoed back in the response. A missing or unreadable `skip_message_ids_path` SHALL be treated as an empty skip-set (no skips) with a stderr note, not a hard error — a first-ever archive has no prior index. Message-ID matching SHALL be exact and case-sensitive on the full Message-ID string as emitted by `get_email` / the manifest.

When `skip_message_ids_path` is omitted, behavior SHALL be identical to before this requirement (no skipping; no `skipped`-status items; the `skipped` count SHALL be `0`).

#### Scenario: already-archived emails are skipped, not rewritten

- **WHEN** `export_emails_markdown` is called with a set of candidate ids and a `skip_message_ids_path` whose file contains the Message-IDs of some of those candidates
- **THEN** the emails whose Message-IDs are in the file are not written to disk
- **AND** each such email appears in the manifest with `status: "skipped"` and its `message_id`
- **AND** the manifest summary's `skipped` count equals the number of skipped emails

#### Scenario: missing skip-set file is treated as empty, not an error

- **WHEN** `export_emails_markdown` is called with a `skip_message_ids_path` that does not exist or cannot be read
- **THEN** no email is skipped on that basis, all candidates are written normally, and the tool does not return an error for the missing file

#### Scenario: skip-set path outside allowed roots is rejected

- **WHEN** `export_emails_markdown` is called with a `skip_message_ids_path` that resolves outside the allowed write-safety roots (e.g. a denied home-relative or system directory)
- **THEN** the system rejects the call with a write-safety error, consistent with the `output_dir` validation

#### Scenario: omitting the skip-set preserves prior behavior

- **WHEN** `export_emails_markdown` is called without `skip_message_ids_path`
- **THEN** no email is skipped, the manifest contains no `skipped`-status items, and the result is otherwise identical to the pre-skip-set behavior

---
### Requirement: Batch export tool naming and deprecation alias

The system SHALL register the server-side markdown export tool under the canonical name `batch_export_emails_markdown`. The pre-existing name `export_emails_markdown` SHALL remain registered as a deprecated alias: both names SHALL dispatch to the same handler, accept the identical input schema, and return the identical manifest — the two registrations MUST NOT diverge in behaviour in any way. Every normative clause of the "Server-side markdown export" requirement SHALL apply equally to calls made under either name.

The deprecated alias's tool description SHALL begin with the literal prefix `DEPRECATED — renamed to batch_export_emails_markdown` and SHALL state the removal gate. A call made under the deprecated name SHALL emit a single-line deprecation warning to stderr naming the canonical replacement; the call's result content SHALL be unaffected.

The deprecated alias SHALL NOT be removed before the next major release (v3.0). Removing the alias SHALL be treated as a breaking change requiring its own change proposal, CHANGELOG entry, and caller-migration note.

#### Scenario: Canonical name dispatches identically

- **WHEN** `batch_export_emails_markdown` is called with any input that is valid for `export_emails_markdown`
- **THEN** the call SHALL behave exactly as the same call under `export_emails_markdown` — same validation, same files written, same manifest shape — with no deprecation warning emitted

#### Scenario: Deprecated alias still works and warns on stderr

- **WHEN** `export_emails_markdown` is called with a valid input
- **THEN** the call SHALL succeed with identical behaviour and manifest as under the canonical name
- **AND** exactly one deprecation warning line naming `batch_export_emails_markdown` SHALL be written to stderr
- **AND** the returned result SHALL NOT contain the deprecation warning

#### Scenario: Alias description marks deprecation

- **WHEN** the tool list is enumerated
- **THEN** the `export_emails_markdown` entry's description SHALL begin with `DEPRECATED — renamed to batch_export_emails_markdown`
- **AND** the `batch_export_emails_markdown` entry SHALL carry the full (non-deprecated) tool description

#### Scenario: Alias survives until the next major release

- **WHEN** any release with major version 2 is built
- **THEN** both `batch_export_emails_markdown` and `export_emails_markdown` SHALL be present in the tool list
