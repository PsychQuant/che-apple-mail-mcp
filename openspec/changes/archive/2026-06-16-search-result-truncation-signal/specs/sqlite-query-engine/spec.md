# sqlite-query-engine Specification Delta — search-result-truncation-signal

## ADDED Requirements

### Requirement: Search and list result truncation envelope

The system SHALL return `search_emails` and `list_emails` results as a JSON envelope object with the keys `results`, `returned`, `limit`, and `truncated`, rather than a bare array. `results` SHALL be the array of result objects (each object retaining all fields defined by "Search result format backward compatibility"). `returned` SHALL be the integer count of objects in `results`. `limit` SHALL be the effective limit applied to the query. `truncated` SHALL be a boolean indicating whether more rows matched than were returned.

On the SQLite fast path the system SHALL determine `truncated` definitively by fetching up to `limit + 1` rows internally, returning at most `limit`, and setting `truncated` to true when more than `limit` rows matched. On the AppleScript fallback path (when the SQLite index is unavailable) the system MAY determine `truncated` heuristically as `returned == limit`, and this heuristic nature SHALL be documented in the tool description.

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

## MODIFIED Requirements

### Requirement: Search result sorting and limiting

The system SHALL sort search results by `messages.date_received` in descending order by default (newest first). The system SHALL support a `sort` parameter with values `desc` (default) and `asc`. The system SHALL limit the returned results to the value of the `limit` parameter (default: 50). To signal truncation definitively, the SQLite fast path SHALL fetch up to `limit + 1` rows internally, return at most `limit` rows, and report `truncated = true` when more than `limit` rows matched (see "Search and list result truncation envelope").

#### Scenario: Default sort order

- **WHEN** `search_emails` is called without a `sort` parameter
- **THEN** results are ordered by date received, newest first

#### Scenario: Custom limit

- **WHEN** `search_emails` is called with `limit: 10`
- **THEN** at most 10 result objects are returned in `results`

### Requirement: Search result format backward compatibility

The system SHALL return search result objects with at minimum the fields: `id`, `subject`, `sender`, `date_received`, `account_name`, `mailbox`. The system SHALL additionally include a `to` field containing the primary To recipient addresses. The `id` field SHALL contain the message ROWID which is directly compatible with AppleScript's `id of message`. These result objects SHALL appear as elements of the `results` array within the truncation envelope (see "Search and list result truncation envelope"); the per-object field set is unchanged by the envelope.

#### Scenario: Result fields include both legacy and new fields

- **WHEN** a search returns results
- **THEN** each object in `results` contains `id` (integer as string), `subject` (string), `sender` (email address string), `date_received` (ISO 8601 formatted string), `account_name` (human-readable string), `mailbox` (decoded mailbox name string), and `to` (array of recipient email address strings)

### Requirement: List emails via SQLite

The system SHALL list emails in a mailbox by querying the Envelope Index database, joining `messages`, `subjects`, `addresses`, and `mailboxes` tables. The system SHALL NOT use AppleScript for listing emails when the SQLite index is available. The system SHALL return the listing as the truncation envelope (see "Search and list result truncation envelope"), with the email objects as elements of `results`.

#### Scenario: List emails in a mailbox

- **WHEN** `list_emails` is called with `mailbox` and `account_name`
- **THEN** the system returns a truncation envelope whose `results` array contains emails with id, subject, sender, and date_received, ordered by date_received descending, limited by the `limit` parameter
- **AND** `truncated` is `true` when more than `limit` emails exist in the mailbox
