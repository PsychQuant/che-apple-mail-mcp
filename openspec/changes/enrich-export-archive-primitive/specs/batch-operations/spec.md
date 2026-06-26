## ADDED Requirements

### Requirement: Batch get emails Message-ID parity

Each per-email result object returned by `get_emails_batch` SHALL include a `message_id` field carrying the resolved RFC 5322 Message-ID of that email, achieving parity with the single `get_email` tool (which already returns `message_id`). When the source email has no Message-ID header, the field SHALL be the empty string rather than absent. This is an additive field; no existing `get_emails_batch` result field is renamed or removed, and per-email `error` entries are unaffected.

#### Scenario: batch result carries message_id per email

- **WHEN** `get_emails_batch` is called for emails that each have a Message-ID header
- **THEN** each successful per-email result object includes a `message_id` field equal to that email's RFC 5322 Message-ID

#### Scenario: missing Message-ID yields empty string, not absence

- **WHEN** `get_emails_batch` processes an email whose source has no Message-ID header
- **THEN** that result object's `message_id` field is the empty string (the field is present)

### Requirement: Markdown export manifest carries Message-ID

Each item in the `export_emails_markdown` manifest SHALL include a `message_id` field carrying the resolved RFC 5322 Message-ID of the exported email (empty string when the source has none, mirroring the existing `in_reply_to` convention). This lets a caller reconcile a Message-ID-keyed archive index from the manifest alone, without re-fetching email content. The field is additive; the markdown/frontmatter/filename output format is unchanged.

#### Scenario: manifest item includes message_id

- **WHEN** `export_emails_markdown` writes an email that has a Message-ID
- **THEN** the corresponding manifest item includes a `message_id` field equal to that email's RFC 5322 Message-ID
- **AND** the written markdown file's format (frontmatter, filename) is unchanged from before this field was added

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
