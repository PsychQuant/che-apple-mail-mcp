## MODIFIED Requirements

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
