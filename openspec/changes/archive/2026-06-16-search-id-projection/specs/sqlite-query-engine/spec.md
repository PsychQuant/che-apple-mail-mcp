# sqlite-query-engine Specification Delta — search-id-projection

## ADDED Requirements

### Requirement: Search result projection and logical dedup

The system SHALL support an optional `projection` parameter on `search_emails` with the values `full` (default), `ids`, and `count`, and an optional `dedup` parameter with the values `none` (default) and `logical`. These parameters are additive: when both are omitted the response SHALL be byte-identical to the default full-row truncation envelope ("Search and list result truncation envelope").

The `projection` values SHALL behave as:

- `full` — the system SHALL return the full truncation envelope `{ results, returned, limit, truncated }` where each element of `results` is a result object (unchanged default behavior).
- `ids` — the system SHALL return the envelope `{ results, returned, limit, truncated }` where `results` is an array of message rowId **strings** and no other per-row fields. The system SHALL produce this result without performing the per-row recipient subquery used to populate the `to` field. The system SHALL apply the same definitive `limit + 1` truncation semantics as the full path (fetch up to `limit + 1`, return at most `limit`, `truncated = true` when more matched).
- `count` — the system SHALL return `{ count }` where `count` is the integer total number of matches, ignoring `limit` (no `LIMIT` clause is applied).

The `dedup` value `logical` SHALL collapse mailbox-duplicate rows — rows sharing the same `(subject, sender address, date_received)` — into a single representative row using `GROUP BY` on those index columns and `MIN(ROWID)`, so that a logical email surfaced in multiple mailboxes (e.g. Gmail `INBOX` / `Archive` / `All Mail`) is returned at most once. The dedup key is the Envelope-Index-available tuple, not the RFC Message-ID; the system SHALL NOT read `.emlx` files to dedup. With `projection: "ids"` the `truncated` flag SHALL be computed over the deduplicated groups; with `projection: "count"` the count SHALL be the number of deduplicated groups.

The system SHALL reject invalid combinations with a parameter error: an unrecognized `projection` or `dedup` value, or `dedup: "logical"` combined with `projection: "full"` (full-row dedup is not supported). The `ids` and `count` projections require the SQLite envelope index; when the index is unavailable the system SHALL return a parameter error rather than silently degrading to the AppleScript fallback.

#### Scenario: ids projection returns rowId strings only

- **WHEN** `search_emails` is called with `projection: "ids"`
- **THEN** the response is an envelope `{ results, returned, limit, truncated }` whose `results` is an array of message rowId strings
- **AND** no per-row recipient (`to`) subquery is performed to build the result

#### Scenario: ids projection preserves definitive truncation

- **WHEN** `search_emails` is called with `projection: "ids"`, `limit: 10`, and 11 or more messages match
- **THEN** exactly 10 rowId strings are returned and `truncated` is `true`

#### Scenario: count projection returns total ignoring limit

- **WHEN** `search_emails` is called with `projection: "count"` and `limit: 1` while 42 messages match
- **THEN** the response is `{ count: 42 }`

#### Scenario: logical dedup collapses mailbox duplicates

- **WHEN** a logical email appears in three mailboxes (same subject, sender, and date_received) and `search_emails` is called with `projection: "ids"` and `dedup: "logical"`
- **THEN** that logical email contributes exactly one rowId to `results`

#### Scenario: dedup with full projection is rejected

- **WHEN** `search_emails` is called with `projection: "full"` and `dedup: "logical"`
- **THEN** the system returns a parameter error

#### Scenario: non-default projection requires the SQLite index

- **WHEN** `search_emails` is called with `projection: "ids"` (or `count`) while the SQLite envelope index is unavailable
- **THEN** the system returns a parameter error rather than falling back to AppleScript

## MODIFIED Requirements

### Requirement: Search and list result truncation envelope

The system SHALL return `search_emails` and `list_emails` results as a JSON envelope object with the keys `results`, `returned`, `limit`, and `truncated`, rather than a bare array. `results` SHALL be the array of result objects (each object retaining all fields defined by "Search result format backward compatibility"). `returned` SHALL be the integer count of objects in `results`. `limit` SHALL be the effective limit applied to the query. `truncated` SHALL be a boolean indicating whether more rows matched than were returned.

On the SQLite fast path the system SHALL determine `truncated` definitively by fetching up to `limit + 1` rows internally, returning at most `limit`, and setting `truncated` to true when more than `limit` rows matched. On the AppleScript fallback path (when the SQLite index is unavailable) the system MAY determine `truncated` heuristically as `returned == limit`, and this heuristic nature SHALL be documented in the tool description.

The shape of the envelope's `results` MAY vary by the `projection` parameter (see "Search result projection and logical dedup"): the default `projection: "full"` retains the result-object shape described above; `projection: "ids"` makes `results` an array of rowId strings within the same `{ results, returned, limit, truncated }` envelope; `projection: "count"` replaces the envelope entirely with `{ count }`. This requirement describes the default `full` projection; the `ids` and `count` variants are normatively defined by "Search result projection and logical dedup".

#### Scenario: Envelope wraps the results array

- **WHEN** `search_emails` or `list_emails` returns
- **THEN** the response is a JSON object containing `results` (array), `returned` (integer), `limit` (integer), and `truncated` (boolean), not a bare array
- **AND** each element of `results` retains the fields `id`, `subject`, `sender`, `date_received`, `account_name`, `mailbox` (and `to` for search results)

#### Scenario: Truncation detected when more than limit match (SQLite fast path)

- **WHEN** `search_emails` is called with `limit: 10` and 11 or more messages match
- **THEN** exactly 10 objects are returned in `results`
- **AND** `truncated` is `true`

#### Scenario: No truncation when matches fit within limit (SQLite fast path)

- **WHEN** `search_emails` is called with `limit: 10` and exactly 10 or fewer messages match
- **THEN** `truncated` is `false`
