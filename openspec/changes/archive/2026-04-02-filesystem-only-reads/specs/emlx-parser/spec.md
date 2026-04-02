## ADDED Requirements

### Requirement: Get email headers via emlx

The system SHALL provide raw email headers by reading and parsing the .emlx file's RFC 822 header section. The system SHALL NOT use AppleScript for header retrieval.

#### Scenario: Get headers for a message

- **WHEN** `get_email_headers` is called with a message `id`
- **THEN** the system resolves the .emlx path, reads the file, and returns the raw header text (everything before the blank line separating headers from body)

#### Scenario: Fallback when emlx unavailable

- **WHEN** `get_email_headers` is called and the .emlx file does not exist
- **THEN** the system falls back to the AppleScript-based header retrieval

### Requirement: Get email source via emlx

The system SHALL provide raw email source (full RFC 822 message) by reading the .emlx file. The system SHALL NOT use AppleScript for source retrieval.

#### Scenario: Get source for a message

- **WHEN** `get_email_source` is called with a message `id`
- **THEN** the system resolves the .emlx path, reads the file, extracts the RFC 822 message data (between byte count line and trailing plist), and returns it as a string

#### Scenario: Fallback when emlx unavailable

- **WHEN** `get_email_source` is called and the .emlx file does not exist
- **THEN** the system falls back to the AppleScript-based source retrieval
