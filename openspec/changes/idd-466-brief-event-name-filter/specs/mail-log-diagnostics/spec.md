## Purpose

The mail-log-diagnostics capability lets a caller read recent events that Mail wrote to the macOS unified log, so that a chain of Mail-internal events can be inspected and the step at which the chain stops can be located. It is an observation channel only and never a source of truth for Mail state.

## ADDED Requirements

### Requirement: Event-name filter

The system SHALL accept an optional parameter `events` in both `brief` and `detailed` detail. When given, `events` SHALL be an array of 1 to 20 strings, each of 1 to 1024 bytes of UTF-8 (1024 bytes is the longest `formatString` that can be displayed; a longer one is always withheld); values that are identical byte for byte SHALL be collapsed, keeping the first occurrence of each. A value whose first five bytes are `imap.` with its letters in any ASCII case, and that is not byte for byte the name of a known event, SHALL be rejected, so that a misspelled known-event name cannot read as an event that did not happen. A wrong JSON type, an empty array, more than 20 entries, or an entry outside the length bounds SHALL produce an invalid-parameter error, and on any of these errors the system SHALL NOT spawn the log reader. The values SHALL NOT be passed to the log reader; the filter is applied to parsed events.

The system SHALL keep an event only when its displayed event name is exactly equal, comparing Unicode scalars and distinguishing case, to one of the values. The displayed event name SHALL be the value the response would carry in the event's `event` field, and the system SHALL compute it with the same function for the filter and for the output: `<template withheld>` for a withheld `formatString`, the `formatString` itself for a composed message longer than 65536 bytes of UTF-8, the name of a known event for a recognized known event, and the `formatString` otherwise. A withheld `formatString` SHALL therefore be selectable only as `<template withheld>` and never by its own text, and a recognized upload receipt only as `imap.append_uid_received` and never by its `formatString`. No substring, prefix, or case-insensitive match SHALL select an event. When `contains` is also given, an event SHALL satisfy both filters.

The filter SHALL be applied where `contains` is applied: after an in-window event has advanced the scan frontier and before the request's `offset` is consumed. Events that the filter rejects SHALL NOT count toward `limit`, SHALL NOT be counted by `offset` or `next_offset`, and SHALL still advance the scan frontier that a `scan_cap` or `deadline` cursor uses. The response SHALL carry a field `event_filter_count` holding the number of normalized values, or `null` when the parameter was not given, in both an answered and an `unavailable` response. The response SHALL NOT echo the values themselves: escaped as JSON, 20 values of 1024 bytes can exceed the 65536-byte response cap on their own, and they are caller text, which brief output does not carry. With any `events` value the response SHALL stay within that cap, and the values SHALL NOT change the stop reason or the cursor except through which events match. An error about an `events` value SHALL NOT quote the value. When no event matches, `notice` SHALL state that the event-name filter was applied, in addition to the statement that the absence of events does not establish that the action did not occur.

#### Scenario: The upload receipt is found among noise

- **GIVEN** a window holding 300 `IMAPConnection` events whose displayed name is the template `%{public}@`, and one recognized upload receipt after them
- **WHEN** the tool is called in `brief` detail with `events` equal to `["imap.append_uid_received"]` and `limit` equal to 1
- **THEN** the response returns exactly the receipt, with `truncated` equal to `false`, and the noise events do not count toward `limit`

#### Scenario: A withheld template is not addressable by its text

- **GIVEN** an event whose `formatString` is withheld because it contains an email-shaped string
- **WHEN** the tool is called with `events` equal to a list holding that `formatString`
- **THEN** no event is returned, and calling with `events` equal to `["<template withheld>"]` returns the event with `event` equal to `<template withheld>`

#### Scenario: A misspelled known-event name is rejected before reading

- **WHEN** the tool is called with `events` equal to `["imap.append_uid_recieved"]`
- **THEN** the system returns an invalid-parameter error that names the known events and spawns no subprocess

##### Example: event-name filter validation

| Input | Result |
| --- | --- |
| `events` = `["imap.append_uid_received"]` | accepted |
| `events` = `["%@ Received %lu new local message actions"]` with `detail` = `brief` | accepted |
| `events` = `["<template withheld>"]` | accepted |
| `events` = `["imap.append_uid_recieved"]` | error: unknown known-event name |
| `events` = `["IMAP.append_uid_received"]` | error: unknown known-event name |
| `events` = `["imap."]` | error: unknown known-event name |
| `events` = `["imap"]` (four bytes, no dot) | accepted |
| `events` = `["imap.\u0301append_uid_received"]` (a combining mark after the dot) | error: unknown known-event name |
| `events` = `[]` | error: empty |
| `events` with 21 entries | error: more than 20 |
| `events` = `[""]` | error: entry length out of range |
| `events` = an entry of 1025 bytes of UTF-8 | error: entry length out of range |
| `events` = an entry of 1024 bytes of UTF-8 | accepted |
| `events` = `"imap.append_uid_received"` (a string, not an array) | error: must be an array |
| `events` = `[1]` | error: entries must be strings |
| `events` = `["a", "a", "b"]` | accepted; normalized to `["a", "b"]`, `event_filter_count` = 2 |
| `events` = `["Caf\u00E9 %@", "Cafe\u0301 %@"]` | accepted; both kept (they differ in bytes), `event_filter_count` = 2 |

##### Example: event-name filter matching

| Event | `events` value | Kept |
| --- | --- | --- |
| `formatString` `%@ Received %lu new local message actions` | `%@ Received %lu new local message actions` | yes |
| `formatString` `%@ Received %lu new local message actions` | `%@ received %lu new local message actions` | no (case differs) |
| `formatString` `%@ Received %lu new local message actions` | `Received` | no (substring) |
| recognized upload receipt, `formatString` `%{public}@` | `imap.append_uid_received` | yes |
| recognized upload receipt, `formatString` `%{public}@` | `%{public}@` | no |
| unrecognized `IMAPConnection` event, `formatString` `%{public}@` | `%{public}@` | yes |
| withheld `formatString` that contains an email-shaped string | that `formatString` | no |
| withheld `formatString` that contains an email-shaped string | `<template withheld>` | yes |
| composed message of 65537 bytes, `formatString` `%{public}@` | `%{public}@` | yes |
| withheld `formatString` with a composed message of 65537 bytes | that `formatString` | no |
| withheld `formatString` with a composed message of 65537 bytes | `<template withheld>` | yes |

##### Example: event-name filter paging

| Situation | Result |
| --- | --- |
| five events share the start millisecond in this reader order: non-matching, matching (first), non-matching, matching (second), matching (third); request `since` = that millisecond, `offset` = 1, `limit` = 1 | returns the second matching event, not the first; `next_offset` = 2 |
| a `scan_cap` stop after matching events and later non-matching events | `next_start` is the time of the last in-window event read, matching or not |
| no event matches and the window is read to its end | `status` = `no_events_in_window`, `event_filter_count` = the number of values, `notice` names the event-name filter |
| 20 values of 1024 bytes of control characters, no event matches, window read to its end | response within 65536 bytes, `truncated` = `false`, `stopped_by` = `null`, no value echoed |
| `events` not given | response field `event_filter_count` = `null` |
