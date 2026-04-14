# emlx-parser Specification Delta — save-attachment-fast-path

## ADDED Requirements

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
