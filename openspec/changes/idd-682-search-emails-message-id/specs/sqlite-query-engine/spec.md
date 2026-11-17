## Purpose

Lets a caller that de-duplicates on Message-ID (the `/archive-mail` SOP) get it from `search_emails` instead of reading raw header text one message at a time.

## MODIFIED Requirements

### Requirement: Search result projection and logical dedup

The system SHALL support an optional `projection` parameter on `search_emails` with the values `full` (default), `ids`, `summary`, and `count`, and an optional `dedup` parameter with the values `none` (default) and `logical`. These parameters are additive: when both are omitted the response SHALL be byte-identical to the default full-row truncation envelope ("Search and list result truncation envelope").

The `projection` values SHALL behave as:

- `full` — the system SHALL return the full truncation envelope `{ results, returned, limit, truncated }` where each element of `results` is a result object (unchanged default behavior).
- `ids` — the system SHALL return the envelope `{ results, returned, limit, truncated }` where `results` is an array of message rowId **strings** and no other per-row fields. The system SHALL produce this result without performing the per-row recipient subquery used to populate the `to` field. The system SHALL apply the same definitive `limit + 1` truncation semantics as the full path (fetch up to `limit + 1`, return at most `limit`, `truncated = true` when more matched).
- `summary` — the system SHALL return the envelope `{ results, returned, limit, truncated }` where each element of `results` is a triage object containing exactly the fields `id`, `date`, `sender`, `subject`, and `mailbox` (and no other fields — in particular no `to`/`cc` recipient lists and no duplicate account fields), plus `message_id` only when the caller asks for it ("`search_emails` returns the Message-ID on request"); a call that does not set `include_message_id` gets exactly the fields listed. `date` SHALL be formatted as the same ISO 8601 representation used by the `full` projection's `date_received`. The system SHALL produce this result without performing the per-row recipient subquery. The system SHALL apply the same definitive `limit + 1` truncation semantics as the `full` and `ids` paths.
- `count` — the system SHALL return `{ count }` where `count` is the integer total number of matches, ignoring `limit` (no `LIMIT` clause is applied).

The `dedup` value `logical` SHALL collapse mailbox-duplicate rows — rows sharing the same `(subject, sender address, date_received)` — into a single representative row using `GROUP BY` on those index columns and `MIN(ROWID)`, so that a logical email surfaced in multiple mailboxes (e.g. Gmail `INBOX` / `Archive` / `All Mail`) is returned at most once. The dedup key is the Envelope-Index-available tuple, not the RFC Message-ID; the system SHALL NOT read `.emlx` files to dedup. With `projection: "ids"` or `projection: "summary"` the `truncated` flag SHALL be computed over the deduplicated groups, and each surviving group SHALL be represented by its `MIN(ROWID)` row; with `projection: "count"` the count SHALL be the number of deduplicated groups.

The system SHALL reject invalid combinations with a parameter error: an unrecognized `projection` or `dedup` value, `include_message_id: true` combined with `projection: "ids"` or `"count"` (those return no row objects), or `dedup: "logical"` combined with `projection: "full"` (full-row dedup is not supported; `summary` IS supported because it performs no recipient subquery). The `ids`, `summary`, and `count` projections require the SQLite envelope index; when the index is unavailable the system SHALL return a parameter error rather than silently degrading to the AppleScript fallback.

#### Scenario: ids projection returns rowId strings only

- **WHEN** `search_emails` is called with `projection: "ids"`
- **THEN** the response is an envelope `{ results, returned, limit, truncated }` whose `results` is an array of message rowId strings
- **AND** no per-row recipient (`to`) subquery is performed to build the result

#### Scenario: ids projection preserves definitive truncation

- **WHEN** `search_emails` is called with `projection: "ids"`, `limit: 10`, and 11 or more messages match
- **THEN** exactly 10 rowId strings are returned and `truncated` is `true`

#### Scenario: summary projection returns triage fields only

- **WHEN** `search_emails` is called with `projection: "summary"`
- **THEN** the response is an envelope `{ results, returned, limit, truncated }` whose `results` elements each contain exactly `id`, `date`, `sender`, `subject`, and `mailbox`
- **AND** no `to`/`cc` recipient lists or duplicate account fields are present
- **AND** no per-row recipient subquery is performed to build the result

#### Scenario: summary projection preserves definitive truncation

- **WHEN** `search_emails` is called with `projection: "summary"`, `limit: 10`, and 11 or more messages match
- **THEN** exactly 10 triage objects are returned and `truncated` is `true`

#### Scenario: count projection returns total ignoring limit

- **WHEN** `search_emails` is called with `projection: "count"` and `limit: 1` while 42 messages match
- **THEN** the response is `{ count: 42 }`

#### Scenario: logical dedup collapses mailbox duplicates

- **WHEN** a logical email appears in three mailboxes (same subject, sender, and date_received) and `search_emails` is called with `projection: "ids"` and `dedup: "logical"`
- **THEN** that logical email contributes exactly one rowId to `results`

#### Scenario: summary projection with logical dedup collapses mailbox duplicates

- **WHEN** a logical email appears in three mailboxes (same subject, sender, and date_received) and `search_emails` is called with `projection: "summary"` and `dedup: "logical"`
- **THEN** that logical email contributes exactly one triage object to `results`, representing its `MIN(ROWID)` row

#### Scenario: dedup with full projection is rejected

- **WHEN** `search_emails` is called with `projection: "full"` and `dedup: "logical"`
- **THEN** the system returns a parameter error

#### Scenario: non-default projection requires the SQLite index

- **WHEN** `search_emails` is called with `projection: "ids"` (or `summary`, or `count`) while the SQLite envelope index is unavailable
- **THEN** the system returns a parameter error rather than falling back to AppleScript

## ADDED Requirements

### Requirement: search_emails returns the Message-ID on request

`search_emails` SHALL accept an optional boolean `include_message_id`, default `false`. A value that is present and not a boolean SHALL be a parameter error. When it is not `true`, the system SHALL read no `.emlx` file to build the result, and each row SHALL be byte-identical to the row the same call returns without the parameter. When it is `true` with projection `full` or `summary`, the system SHALL add a `message_id` key to each row, read from the `.emlx` header block of the row's message and parsed with the function that `get_email`, `get_emails_batch` and the batch export use for their `message_id` (`RFC822Parser.parseHeaders`, key `message-id`), so that whenever the key is present its value equals what those tools report for the same message. Each row SHALL be in exactly one of three states:

- a non-empty string: the parsed Message-ID value (angle brackets kept, as `get_email` reports it);
- the empty string: the header block was read and has no `Message-ID` header (as `get_email` reports it);
- the key omitted: the value could not be read or is not returned: no readable `.emlx` for the row (including a body not downloaded and no partial file, and mailboxes that keep no `.emlx`), a read or parse error, a value longer than 4096 bytes (UTF-8), a header block larger than 256 KiB, or a path that does not fill it (the AppleScript fallback).

A row SHALL never be dropped, and its other fields SHALL not change, because its `message_id` could not be read. A read that fails SHALL be reported once per call on stderr through `Diagnostics.emit`, naming a fixed reason and the count of affected rows and never any header text. The system SHALL read only as much of each `.emlx` as is needed to find the end of the header block (a bounded, chunked read) and SHALL never look at more than the first 256 KiB of a message, whatever its line endings and whether or not it has a header/body separator; a message whose header block is not finished within that bound is in the omitted-key state. The system SHALL resolve the mailbox's store folder once per mailbox per call. With `dedup: "logical"` and projection `summary`, the value SHALL be the one of the kept `MIN(ROWID)` row. The value SHALL be the parsed Message-ID only, never the raw header block.

#### Scenario: The flag is off

- **WHEN** `search_emails` is called with `projection: "full"` or `"summary"` and without `include_message_id` (or with `false`)
- **THEN** no row has a `message_id` key and no `.emlx` file is read

#### Scenario: The value equals the one get_email reports

- **WHEN** `search_emails` is called with `include_message_id: true` for a message whose header block has a folded `Message-ID`, an RFC 2047 encoded one, duplicate `Message-ID` headers, CR-only, LF-only or CRLF line ends, or a value without angle brackets
- **THEN** the row's `message_id` equals `message_id` from `get_email` for the same message, and equals the batch export's

#### Scenario: A message without the header

- **WHEN** the `.emlx` header block has no `Message-ID` header
- **THEN** the row's `message_id` is the empty string

#### Scenario: An unreadable message

- **WHEN** a row's `.emlx` file is missing, truncated, its value is longer than 4096 UTF-8 bytes (counted in bytes, so a short string of combining marks is over the limit), or its header block is not finished within 256 KiB
- **THEN** the row is still returned with its other fields, its `message_id` key is omitted, and one line is written to stderr for the call

#### Scenario: Projections without rows

- **WHEN** `include_message_id: true` is combined with `projection: "ids"` or `"count"`
- **THEN** the system returns a parameter error

#### Scenario: The AppleScript fallback

- **WHEN** `include_message_id: true` and the SQLite index is unavailable for projection `full`
- **THEN** the rows come from the AppleScript fallback and carry no `message_id` key
