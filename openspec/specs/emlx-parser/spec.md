# emlx-parser Specification

## Purpose

TBD - created by archiving change 'sqlite-search-engine'. Update Purpose after archive.

## Requirements

### Requirement: Emlx file path resolution

The system SHALL resolve the filesystem path of a `.emlx` file from a message ROWID and mailbox URL. The path pattern is `~/Library/Mail/V10/<account-uuid>/<mailbox-path>.mbox/<store-uuid>/Data/<hash>/Messages/<ROWID>.emlx`, where `<hash>` is a **variable-depth** slash-separated sequence of decimal digits derived from `rowId / 1000`, emitted right-to-left. When `rowId < 1000` the hash is empty and the file lives directly under `Data/Messages/<ROWID>.emlx`. The system SHALL locate the store UUID subdirectory by scanning the mailbox `.mbox` directory for a UUID-formatted subdirectory.

The depth rule (verified against 256,428 real `.emlx` files on macOS Sequoia / Tahoe — see issue #9):

- `rowId < 1000` → depth 0, path = `Data/Messages/<id>.emlx`
- `1000 ≤ rowId < 10000` → depth 1, path = `Data/d4/Messages/`
- `10000 ≤ rowId < 100000` → depth 2, path = `Data/d4/d5/Messages/`
- `100000 ≤ rowId < 1000000` → depth 3, path = `Data/d4/d5/d6/Messages/`
- …and so on for 7+ digit ROWIDs

where `d4 = (rowId / 1000) % 10`, `d5 = (rowId / 10000) % 10`, etc.

#### Scenario: Resolve path for a depth-3 message

- **WHEN** the system resolves the path for ROWID 262653 in mailbox URL `ews://ABCE3A85.../收件匣`
- **THEN** the system produces path `~/Library/Mail/V10/ABCE3A85-.../收件匣.mbox/<store-uuid>/Data/2/6/2/Messages/262653.emlx`

#### Scenario: Depth-1 ROWID

- **WHEN** the system resolves the path for ROWID 9865
- **THEN** the hash directory path is `9/Messages/9865.emlx` (single level, `9865 / 1000 = 9`)

#### Scenario: Depth-2 ROWID

- **WHEN** the system resolves the path for ROWID 19926
- **THEN** the hash directory path is `9/1/Messages/19926.emlx` (`19926 / 1000 = 19 → 9, 1`)

#### Scenario: ROWID below 1000 (no hash dir)

- **WHEN** the system resolves the path for ROWID 218
- **THEN** the file lives directly at `Data/Messages/218.emlx` with no intermediate hash subdirectories

#### Scenario: Emlx file does not exist

- **WHEN** the resolved `.emlx` path does not exist on disk
- **THEN** the system attempts `.partial.emlx` at the same path, and if neither exists, returns an error indicating the message content is unavailable from the filesystem

#### Scenario: Nested mailbox path

- **WHEN** the mailbox URL path contains multiple segments like `Work/Projects`
- **THEN** the system maps this to `Work.mbox/Projects.mbox/` on the filesystem


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
### Requirement: Emlx file format parsing

The system SHALL parse `.emlx` files according to the Apple Mail format: line 1 contains the byte count of the RFC 822 message data as a decimal integer string, followed by the raw RFC 822 message of exactly that byte count, optionally followed by an Apple plist XML metadata section.

#### Scenario: Parse well-formed emlx file

- **WHEN** the system reads an `.emlx` file whose first line is "75987"
- **THEN** the system reads exactly 75987 bytes after the first newline as the RFC 822 message content

#### Scenario: Parse emlx with trailing plist

- **WHEN** the system reads an `.emlx` file with data beyond the declared byte count
- **THEN** the system ignores the trailing plist metadata and processes only the RFC 822 portion


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
### Requirement: RFC 822 header parsing

The system SHALL parse RFC 822 headers from the message data, including: From, To, CC, Subject, Date, Content-Type, Content-Transfer-Encoding, MIME-Version, and Message-Id. The system SHALL handle RFC 2047 encoded-word syntax (e.g., `=?utf-8?B?...?=` for Base64, `=?utf-8?Q?...?=` for Quoted-Printable) in header values. The system SHALL handle header line folding (continuation lines starting with whitespace).

#### Scenario: Decode Base64-encoded UTF-8 subject

- **WHEN** the system parses a Subject header containing `=?utf-8?B?5pel5pys6Kqe?=`
- **THEN** the decoded subject is "日本語"

#### Scenario: Decode Quoted-Printable header

- **WHEN** the system parses a From header containing `=?utf-8?Q?=E9=84=AD=E6=BE=88?= <kiki830621@gmail.com>`
- **THEN** the decoded display name is "鄭澈" with email address "kiki830621@gmail.com"

#### Scenario: Multi-line folded header

- **WHEN** a Subject header spans multiple lines with continuation whitespace
- **THEN** the system concatenates the lines (removing the CRLF and leading whitespace) before decoding


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
### Requirement: MIME body parsing

The system SHALL parse the message body based on the Content-Type header. For `text/plain`, the system SHALL return the decoded text. For `text/html`, the system SHALL return the HTML content. For `multipart/*` types, the system SHALL recursively parse MIME boundaries to extract text and HTML parts. The system SHALL apply Content-Transfer-Encoding decoding (Base64, Quoted-Printable, 7bit, 8bit) and charset conversion.

#### Scenario: Plain text message

- **WHEN** the Content-Type is `text/plain; charset=utf-8` and Content-Transfer-Encoding is `7bit`
- **THEN** the system returns the body as a UTF-8 string

#### Scenario: HTML message

- **WHEN** the Content-Type is `text/html; charset=utf-8` and Content-Transfer-Encoding is `base64`
- **THEN** the system Base64-decodes the body and returns the HTML content

#### Scenario: Multipart alternative message

- **WHEN** the Content-Type is `multipart/alternative` with a boundary
- **THEN** the system parses both `text/plain` and `text/html` parts, returning both with `text/html` preferred for the default `html` format

#### Scenario: Nested multipart message

- **WHEN** the Content-Type is `multipart/mixed` containing a `multipart/alternative` part and attachment parts
- **THEN** the system recursively parses to find the text/html content parts, ignoring attachment parts

#### Scenario: Non-UTF-8 charset

- **WHEN** a text part has `charset=big5` or `charset=iso-2022-jp`
- **THEN** the system converts the content to UTF-8 using `String.Encoding` or `CFStringConvertEncodingToNSStringEncoding`


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
### Requirement: Get email content via emlx

The system SHALL provide a method to retrieve full email content (subject, sender, recipients, date, body) by reading and parsing the `.emlx` file directly, without invoking AppleScript. The `get_email` MCP tool SHALL use this method as the primary content source when the `.emlx` file is available.

#### Scenario: Get email content successfully from emlx

- **WHEN** `get_email` is called with a valid message ID and the corresponding `.emlx` file exists
- **THEN** the system reads and parses the `.emlx` file, returning subject, sender, date, recipients (to/cc), and body content in the requested format (html/text/source)

#### Scenario: Fallback to AppleScript when emlx unavailable

- **WHEN** `get_email` is called and the `.emlx` file does not exist or cannot be parsed
- **THEN** the system falls back to the existing AppleScript-based `getEmail` method and returns the content from AppleScript

#### Scenario: Source format returns raw RFC 822

- **WHEN** `get_email` is called with `format: "source"`
- **THEN** the system returns the raw RFC 822 message data from the `.emlx` file (bytes between the byte count line and the trailing plist)

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
### Requirement: Get email headers via emlx

The system SHALL provide raw email headers by reading and parsing the .emlx file's RFC 822 header section. The system SHALL NOT use AppleScript for header retrieval.

#### Scenario: Get headers for a message

- **WHEN** `get_email_headers` is called with a message `id`
- **THEN** the system resolves the .emlx path, reads the file, and returns the raw header text (everything before the blank line separating headers from body)

#### Scenario: Fallback when emlx unavailable

- **WHEN** `get_email_headers` is called and the .emlx file does not exist
- **THEN** the system falls back to the AppleScript-based header retrieval


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

---
### Requirement: Get email source via emlx

The system SHALL provide raw email source (full RFC 822 message) by reading the .emlx file. The system SHALL NOT use AppleScript for source retrieval.

#### Scenario: Get source for a message

- **WHEN** `get_email_source` is called with a message `id`
- **THEN** the system resolves the .emlx path, reads the file, extracts the RFC 822 message data (between byte count line and trailing plist), and returns it as a string

#### Scenario: Fallback when emlx unavailable

- **WHEN** `get_email_source` is called and the .emlx file does not exist
- **THEN** the system falls back to the AppleScript-based source retrieval

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

---
### Requirement: Attachment extraction from emlx

The system SHALL provide a non-lossy MIME part enumeration API and an attachment extraction flow that reads `.emlx` files directly, bypassing AppleScript IPC with Mail.app. The existing text/html `parseBody` code path SHALL remain unchanged.

The enumeration API SHALL be `MIMEParser.parseAllParts(_ bodyData: Data, headers: [String: String]) -> [MIMEPart]` and SHALL return every part contained in the body, including `text/plain`, `text/html`, `multipart/*` children (recursively), and non-text parts that the existing `parseBody` discards.

Each `MIMEPart` SHALL expose: the part's lowercased `headers` dictionary, the MIME type (`contentType` without parameters), the `contentTypeParams` map (including `charset`, `boundary`, `name`), the `contentDisposition` string (`"attachment"`, `"inline"`, or `nil`), the decoded `filename` (with RFC 2231 / RFC 5987 continuation and percent-encoding resolved when present), the `rawBytes` before transfer decoding, and the `decodedData` after base64 / quoted-printable decoding. All fields SHALL be value-type `let` constants and the struct SHALL conform to `Sendable`.

The attachment extraction flow SHALL be exposed as `EnvelopeIndexReader.saveAttachment(messageId: Int, attachmentName: String, destination: URL) throws` (or equivalent entry point on the same type) and SHALL:

1. Resolve the `.emlx` path through `EmlxParser.resolveEmlxPath`, inheriting the `mailStoragePathOverride` test hook used by `EmailContent.readEmail`.
2. Load the file into memory, extract the RFC 822 message data via `EmlxFormat.extractMessageData`, and split headers from body via `RFC822Parser.headerBodySplitOffset`.
3. Call `MIMEParser.parseAllParts` on the body.
4. Locate the first `MIMEPart` whose `filename` (after decoding) or `contentTypeParams["name"]` equals the requested `attachmentName`.
5. Write the located part's `decodedData` to `destination` using a single `Data.write(to:)` call.

The extraction flow SHALL throw a typed error when the message is not indexed, when the `.emlx` file is missing, when MIME parsing fails, when no matching attachment filename is found, or when a single part's decoded size exceeds a hard limit of 100 MB (in which case the error SHALL be distinguishable so the dispatcher can fall through to the AppleScript path without ambiguity).

The `save_attachment` tool dispatcher in `Server.swift` SHALL use a two-tier catch pattern: the SQLite fast path runs inside its own `do/catch`; any thrown error falls through to the existing AppleScript-based `MailController.saveAttachment` in a separate `do/catch`. The two `do/catch` blocks SHALL NOT be collapsed into one, because a single combined `do/catch` would treat a SQLite-path throw as a final error and never invoke the fallback (cf. `#9`'s `get_emails_batch` regression).

The existing `MIMEParser.parseBody` API and the `ParsedEmailContent` struct SHALL NOT change signature or behaviour. The existing AppleScript `MailController.saveAttachment` implementation SHALL remain present as the fallback path.

#### Scenario: Extract plain-ASCII PDF attachment from multipart/mixed emlx

- **WHEN** `EnvelopeIndexReader.saveAttachment` is called with a `messageId` whose `.emlx` file is a `multipart/mixed` message containing one `text/plain` part and one `application/pdf` attachment part named `report.pdf`
- **AND** `attachmentName` equals `"report.pdf"`
- **AND** the PDF part is base64 encoded
- **THEN** the call SHALL succeed without throwing
- **AND** the file at `destination` SHALL contain the base64-decoded PDF bytes byte-for-byte
- **AND** the wall-clock duration SHALL be under 50 milliseconds for a PDF up to 5 MB

#### Scenario: Extract attachment with CJK filename encoded as RFC 5987

- **WHEN** the message contains an attachment part whose header is `Content-Disposition: attachment; filename*=UTF-8''%E4%B8%AD%E6%96%87%E6%AA%94%E6%A1%88.pdf`
- **AND** `saveAttachment` is called with `attachmentName` equal to `"中文檔案.pdf"`
- **THEN** the call SHALL succeed
- **AND** the decoded filename SHALL match the request, regardless of whether the original `filename` parameter used `filename=` or `filename*=` encoding

#### Scenario: Fallback to AppleScript when fast path throws

- **WHEN** `save_attachment` is dispatched for a message
- **AND** `EnvelopeIndexReader.saveAttachment` throws any error (not indexed, parse failure, filename not matched, or size over 100 MB)
- **THEN** the dispatcher SHALL catch that error, log the cause to standard error, and invoke `MailController.saveAttachment` in a separate `do/catch`
- **AND** the eventual result returned to the MCP caller SHALL come from the AppleScript fallback (either a success message or the AppleScript error propagated)

#### Scenario: First-match semantics for duplicate filenames

- **WHEN** the message contains two attachment parts with identical filenames (e.g., two versions of `report.pdf`)
- **AND** `saveAttachment` is called with `attachmentName` equal to `"report.pdf"`
- **THEN** the first part encountered during the depth-first traversal of the multipart tree SHALL be written to `destination`
- **AND** the second part SHALL NOT be written, regardless of its size or Content-Disposition

#### Scenario: parseAllParts and parseBody produce consistent text body

- **WHEN** `MIMEParser.parseAllParts(data, headers)` is called on a `multipart/mixed` body containing one `text/plain` part, one `text/html` part, and one `image/png` attachment
- **AND** `MIMEParser.parseBody(data, headers)` is called on the same input
- **THEN** the `decodedData` of the first `text/plain` part returned by `parseAllParts` SHALL decode to the same String as `parseBody(...).textBody`
- **AND** the `decodedData` of the first `text/html` part returned by `parseAllParts` SHALL decode to the same String as `parseBody(...).htmlBody`

#### Scenario: Large attachment triggers size-based fallback

- **WHEN** `EnvelopeIndexReader.saveAttachment` is called against a message whose matched part has decoded size greater than 100 MB
- **THEN** the call SHALL throw a typed error distinguishable from "not indexed" / "parse failure" / "not found"
- **AND** the dispatcher SHALL catch the error and fall through to the AppleScript path
- **AND** no partial file SHALL be written at `destination`

<!-- @trace
source: save-attachment-fast-path
updated: 2026-04-14
code:
  - Tests/MailSQLiteTests/Fixtures/multipart-nested.expected.bin
  - Sources/MailSQLite/MIMEPart.swift
  - Tests/MailSQLiteTests/MIMEPartTests.swift
  - Tests/MailSQLiteTests/Fixtures/multipart-attachment-cjk.expected.bin
  - Tests/MailSQLiteTests/AttachmentExtractorTests.swift
  - Sources/MailSQLite/MailSQLiteError.swift
  - Tests/MailSQLiteTests/Fixtures/multipart-duplicate-filename.expected-first.bin
  - Tests/MailSQLiteTests/MIMEParserTests.swift
  - Tests/MailSQLiteTests/Fixtures/multipart-attachment-ascii.expected.bin
  - Tests/MailSQLiteTests/Fixtures/multipart-duplicate-filename.emlx
  - CHANGELOG.md
  - Tests/MailSQLiteTests/Fixtures/multipart-attachment-cjk.emlx
  - Sources/MailSQLite/AttachmentExtractor.swift
  - Tests/MailSQLiteTests/Fixtures/multipart-nested.emlx
  - Sources/MailSQLite/MIMEParser.swift
  - Sources/CheAppleMailMCP/Server.swift
  - Tests/MailSQLiteTests/Fixtures/multipart-attachment-ascii.emlx
-->