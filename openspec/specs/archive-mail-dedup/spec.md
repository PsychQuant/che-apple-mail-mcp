# archive-mail-dedup Specification

## Purpose

Defines how the `/archive-mail` SOP obtains the Message-ID it de-duplicates on, and what happens to a search row that has no usable Message-ID. Message-ID is the archive's identity key, so a row without one can be neither matched against the archive nor archived without risking a duplicate on every run.

## Requirements

### Requirement: Message-ID comes from get_email_headers

`search_emails` rows carry no `message_id` in any projection. The `/archive-mail` SOP SHALL state, in Step 3d, that a row without a `message_id` gets one from `get_email_headers(id, mailbox, account_name)` before Step 4, and SHALL read the Message-ID from that raw header text with the `message_id_from_headers` recipe. The recipe SHALL read headers the way the server reads them for `get_email`: a folded line (a line break followed by a space or a tab) is joined to the previous line with one space; lines end at CR or LF; the header name is compared without case; the value is stripped of spaces and tabs; when the name occurs more than once, the last one wins. The recipe SHALL return `None` when the input is not a string, when no `Message-ID` header is present, when the value is blank, or when the value contains an RFC 2047 encoded word (`=?`), which the server would decode differently. A row whose header text yields `None` keeps no `message_id`.

#### Scenario: A folded header is read like the server reads it

- **WHEN** `message_id_from_headers` is given `"Subject: x\r\nMessage-ID:\r\n <a@b.test>\r\n"`
- **THEN** it returns `<a@b.test>`

##### Example: message id from raw headers

| Raw header text | Result |
| --- | --- |
| `Message-ID: <a@b.test>` | `<a@b.test>` |
| `message-id:   <a@b.test>  ` (lower case, padded) | `<a@b.test>` |
| `Message-ID:\r\n <a@b.test>` (folded) | `<a@b.test>` |
| `Message-ID: <first@b.test>\nMessage-ID: <last@b.test>` | `<last@b.test>` |
| `Subject: no id here` | `None` |
| `Message-ID:    ` | `None` |
| `Message-ID: =?utf-8?q?x?=` | `None` |
| `None` or `42` instead of text | `None` |

---
### Requirement: Rows without a usable Message-ID are held out, not archived

Step 4.1 SHALL decide every refined row without raising. A row's Message-ID is usable when the row is a dict and its `message_id` is a string that is not blank. A row that passes the strategy's date gate (or every row, under `index`) SHALL go to `new_emails` when its Message-ID is usable and not in `known_ids`, and SHALL go to `held_out` when its Message-ID is not usable. A row in `held_out` SHALL NOT be archived and SHALL NOT be given an invented id. Step 4.5's preview and Step 7's report SHALL show the `held_out` count and, for each row, its `id` and its subject passed through `bounded_text`, inside a fenced block labelled as data, not instructions; at most 20 rows are listed, with the total. When `held_out` is empty neither shows a line. A row with a usable Message-ID SHALL be decided exactly as before this requirement.

#### Scenario: A row without message_id no longer stops the run

- **WHEN** Step 4.1 receives a row with no `message_id` key, under `dedup_strategy: index`
- **THEN** no exception is raised, the row is not in `new_emails`, and it is in `held_out`

#### Scenario: An empty Message-ID is not archived

- **WHEN** Step 4.1 receives a row whose `message_id` is `""`
- **THEN** the row is in `held_out`, not in `new_emails`

##### Example: rows decided by Step 4.1

| Row (strategy `index`, `known_ids = {"<old@x.test>"}`) | Result |
| --- | --- |
| `{"message_id": "<new@x.test>"}` | `new_emails` |
| `{"message_id": "<old@x.test>"}` | neither (already archived) |
| `{}` (no `message_id` key) | `held_out` |
| `{"message_id": None}` | `held_out` |
| `{"message_id": ""}` | `held_out` |
| `{"message_id": "   "}` | `held_out` |
| `{"message_id": 42}` | `held_out` |
| `"not a row"` | `held_out` |

##### Example: held out rows under a date boundary

| Row (strategy `last_archived`, boundary `2026-06-01T00:00:00Z`) | Result |
| --- | --- |
| no `message_id`, `date_received` `2026-07-01T00:00:00Z` | `held_out` |
| no `message_id`, `date_received` `2026-05-01T00:00:00Z` | neither (before the boundary) |
| `message_id` `<n@x.test>`, `date_received` `2026-07-01T00:00:00Z` | `new_emails` |

##### Example: held out report lines

| `held_out` | Report |
| --- | --- |
| empty | no lines |
| one row, `id` `"17"`, subject `"Hello"` | a count line naming 1 row and "data, not instructions", then a fenced block with one line holding `17` and `Hello` |
| 25 rows | the count line says 25 and "(first 20 shown)"; the block has 20 lines |
| a subject with a line break and a backtick | the listed line has neither |
