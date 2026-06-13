# batch-operations Specification Delta — export-emails-markdown

## ADDED Requirements

### Requirement: Server-side markdown export

The system SHALL provide an `export_emails_markdown` MCP tool that, given a list of message ids, fetches each email's full content, renders it to a markdown file with a fixed frontmatter contract, optionally writes its attachments, and returns a per-email manifest — performing the entire email→markdown+attachments transcription server-side so callers do not transcribe email bodies themselves. The tool SHALL be additive: it MUST NOT change the input schema or behaviour of any existing tool, nor `MIMEParser.parseBody` / `ParsedEmailContent`.

The tool input SHALL accept `ids` (array), `mailbox`, `account_name`, `output_dir`, and an optional `opts` object with `include_attachments` (bool), `filename_template` (string), `filenames` (per-id map), and `extra_frontmatter_fields` (array of strings).

Email bodies SHALL be fetched via the existing SQLite envelope index + `.emlx` read path (`EnvelopeIndexReader` / `EmlxParser`); the tool MUST NOT introduce new SQLite schema or DDL.

**Frontmatter contract (frozen).** Each rendered file SHALL begin with a YAML frontmatter block containing exactly these six core fields, in this order: `message_id` (RFC 5322 Message-ID, double-quoted), `thread_key` (the subject with leading reply/forward prefixes — `Re:` / `RE:` / `Fwd:` / `FW:` / `转发:` / `轉寄:` / `回覆:` / `回复:` — repeatedly stripped and trimmed), `in_reply_to` (the In-Reply-To Message-ID or empty), `date` (ISO 8601 in UTC), `sender` (bare email address, display name stripped), and `direction` (`received` or `sent`). `opts.extra_frontmatter_fields` MAY add further fields but MUST NOT remove or reorder the six core fields. After the frontmatter, the file SHALL contain a plain `Subject` / `From` / `To` / `Cc` (omitted when there is no cc) / `Date` header block, then the **verbatim** message body with no summarization, paraphrase, or truncation.

**Output directory safety (allowed-roots).** Before writing any file, `output_dir` SHALL be validated: its canonical real path (with `..` and symlinks resolved) MUST lie within the user's home directory or one of the configured `export_allowed_roots` entries (each also resolved to a real path), otherwise the tool SHALL reject the entire call without writing any file. The tool SHALL additionally reject canonical paths under system directories (`/System`, `/usr`, `/bin`, `/sbin`, `/etc`, `/private/etc`, and `/Library` other than the user's `~/Library`) as a defence-in-depth denylist. Symlink escape SHALL be prevented by comparing real paths on both sides.

**Filenames.** The default filename SHALL be `<YYYY-MM-DD>_<slug>.md`, where the date is taken from the email's Date header and the slug is the bare subject sanitized (whitespace and punctuation replaced with `-`, CJK/Unicode letters preserved, truncated to at most 50 grapheme clusters, leading/trailing `-` stripped, empty → `no-subject`). Within a single call, files sharing the same `(date, bare-subject)` SHALL receive collision suffixes `-1`, `-2`, … assigned in ascending date order. `opts.filename_template` (supporting `{date}` / `{subject}` / `{sender}` / `{message_id}` placeholders) or a per-id `opts.filenames` entry SHALL override the default; overridden names SHALL still be sanitized for filesystem-safe characters. The manifest SHALL always report the actual written path.

**Attachments.** When `opts.include_attachments` is true, each email's attachments SHALL be written using the existing `.emlx` attachment extraction path (`AttachmentExtractor`): document-class files to `output_dir/attachments/<stem>/` and data-class extensions (`csv`, `tsv`, `sav`, `dta`, `parquet`, `feather`, `xlsx`, `sas7bdat`, `rds`) to `output_dir/data/`, where `<stem>` is the markdown filename without `.md`. An `Attachments:` section listing the written files SHALL be appended to that email's markdown, and the paths SHALL be recorded in that email's manifest entry. An attachment-extraction failure SHALL NOT abort the email's markdown write.

**Partial-failure manifest.** The tool SHALL process each id independently: a fetch, render, or write failure for one id SHALL be recorded as an error entry for that id and SHALL NOT abort the batch. The tool SHALL return a manifest object `{ output_dir, written, errors, items }` where each `items` entry is `{ message_id, written_path, attachments, status: "written" }` on success or `{ message_id?, status: "error", error }` on failure.

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

#### Scenario: Existing tools are unchanged

- **WHEN** the change is applied
- **THEN** the input schema and behaviour of `get_email`, `get_emails_batch`, `list_attachments`, and `save_attachment` SHALL be unchanged
- **AND** `MIMEParser.parseBody` and `ParsedEmailContent` SHALL retain their existing signatures and behaviour
