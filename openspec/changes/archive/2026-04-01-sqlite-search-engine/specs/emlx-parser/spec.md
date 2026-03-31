## ADDED Requirements

### Requirement: Emlx file path resolution

The system SHALL resolve the filesystem path of a `.emlx` file from a message ROWID and mailbox URL. The path pattern is `~/Library/Mail/V10/<account-uuid>/<mailbox-path>.mbox/<store-uuid>/Data/<d1>/<d2>/<d3>/Messages/<ROWID>.emlx` where `d1`, `d2`, `d3` are derived from the ROWID digits (ones, tens, hundreds places respectively). The system SHALL locate the store UUID subdirectory by scanning the mailbox `.mbox` directory for a UUID-formatted subdirectory.

#### Scenario: Resolve path for a known message

- **WHEN** the system resolves the path for ROWID 267597 in mailbox URL `imap://E51B96AC.../[Gmail]/全部郵件`
- **THEN** the system produces path `~/Library/Mail/V10/E51B96AC-.../[Gmail].mbox/全部郵件.mbox/<store-uuid>/Data/7/9/5/Messages/267597.emlx`

#### Scenario: ROWID with fewer than 3 digits

- **WHEN** the system resolves the path for ROWID 42
- **THEN** the hash directory path is `2/4/0/Messages/42.emlx` (ones=2, tens=4, hundreds=0)

#### Scenario: Emlx file does not exist

- **WHEN** the resolved `.emlx` path does not exist on disk
- **THEN** the system attempts `.partial.emlx` at the same path, and if neither exists, returns an error indicating the message content is unavailable from the filesystem

#### Scenario: Nested mailbox path

- **WHEN** the mailbox URL path contains multiple segments like `Work/Projects`
- **THEN** the system maps this to `Work.mbox/Projects.mbox/` on the filesystem

### Requirement: Emlx file format parsing

The system SHALL parse `.emlx` files according to the Apple Mail format: line 1 contains the byte count of the RFC 822 message data as a decimal integer string, followed by the raw RFC 822 message of exactly that byte count, optionally followed by an Apple plist XML metadata section.

#### Scenario: Parse well-formed emlx file

- **WHEN** the system reads an `.emlx` file whose first line is "75987"
- **THEN** the system reads exactly 75987 bytes after the first newline as the RFC 822 message content

#### Scenario: Parse emlx with trailing plist

- **WHEN** the system reads an `.emlx` file with data beyond the declared byte count
- **THEN** the system ignores the trailing plist metadata and processes only the RFC 822 portion

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
