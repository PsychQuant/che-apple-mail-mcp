## MODIFIED Requirements

### Requirement: Search result projection and logical dedup

The system SHALL support an optional `projection` parameter on `search_emails` with the values `full` (default), `ids`, `summary`, and `count`, and an optional `dedup` parameter with the values `none` (default) and `logical`. These parameters are additive: when both are omitted the response SHALL be byte-identical to the default full-row truncation envelope ("Search and list result truncation envelope").

The `projection` values SHALL behave as:

- `full` — the system SHALL return the full truncation envelope `{ results, returned, limit, truncated }` where each element of `results` is a result object (unchanged default behavior).
- `ids` — the system SHALL return the envelope `{ results, returned, limit, truncated }` where `results` is an array of message rowId **strings** and no other per-row fields. The system SHALL produce this result without performing the per-row recipient subquery used to populate the `to` field. The system SHALL apply the same definitive `limit + 1` truncation semantics as the full path (fetch up to `limit + 1`, return at most `limit`, `truncated = true` when more matched).
- `summary` — the system SHALL return the envelope `{ results, returned, limit, truncated }` where each element of `results` is a triage object containing exactly the fields `id`, `date`, `sender`, `subject`, and `mailbox` (and no other fields — in particular no `to`/`cc` recipient lists and no duplicate account fields). `date` SHALL be formatted as the same ISO 8601 representation used by the `full` projection's `date_received`. The system SHALL produce this result without performing the per-row recipient subquery. The system SHALL apply the same definitive `limit + 1` truncation semantics as the `full` and `ids` paths.
- `count` — the system SHALL return `{ count }` where `count` is the integer total number of matches, ignoring `limit` (no `LIMIT` clause is applied).

The `dedup` value `logical` SHALL collapse mailbox-duplicate rows — rows sharing the same `(subject, sender address, date_received)` — into a single representative row using `GROUP BY` on those index columns and `MIN(ROWID)`, so that a logical email surfaced in multiple mailboxes (e.g. Gmail `INBOX` / `Archive` / `All Mail`) is returned at most once. The dedup key is the Envelope-Index-available tuple, not the RFC Message-ID; the system SHALL NOT read `.emlx` files to dedup. With `projection: "ids"` or `projection: "summary"` the `truncated` flag SHALL be computed over the deduplicated groups, and each surviving group SHALL be represented by its `MIN(ROWID)` row; with `projection: "count"` the count SHALL be the number of deduplicated groups.

The system SHALL reject invalid combinations with a parameter error: an unrecognized `projection` or `dedup` value, or `dedup: "logical"` combined with `projection: "full"` (full-row dedup is not supported; `summary` IS supported because it performs no recipient subquery). The `ids`, `summary`, and `count` projections require the SQLite envelope index; when the index is unavailable the system SHALL return a parameter error rather than silently degrading to the AppleScript fallback.

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
