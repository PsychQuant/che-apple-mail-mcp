# archive-mail-thread-order Specification

## Purpose

Defines how the `/archive-mail` date recipe orders the messages of a thread (`thread_sort_key`, `thread_order`, `thread_bounds`), which `/archive-mail`, `/archive-mail-rebuild-threads` and `/archive-mail-view` share. The archive stores each message's date as written, so the order is the best one the stored text allows, and the recipe says where it cannot be exact.

## Requirements

### Requirement: A date whose zone cannot be read is placed by its day

`thread_sort_key` SHALL order a thread's messages as follows. A value `parse_archive_date` reads with a known zone SHALL be placed by its UTC day and time; a value it reads without a zone, or as a date only, SHALL be placed by the day (and time) as written, a date-only value at the start of the day. A value `parse_archive_date` cannot read but `to_ymd` gives a day for (for example a zone name the recipe refuses, such as a bare `CST`) SHALL be placed at the start of that day, like a date-only value. A value neither reads SHALL sort after every placed value. A value `parse_archive_date` reads but whose UTC conversion overflows SHALL also sort after every placed value. Ties SHALL be broken by file name, so the order does not depend on the input order. `thread_order` SHALL list as unreadable every value `parse_archive_date` cannot read, the day-placed ones included, and every value whose UTC conversion overflows. `thread_bounds` SHALL use only values `parse_archive_date` reads and that convert to UTC; a day-placed value SHALL NOT become `first_message` or `last_message`. An RFC `-0000` time SHALL sort at the position of the same time written with `Z`.

#### Scenario: Refused zone names no longer sort months late

- **WHEN** `thread_order` receives messages dated `2026-01-01T00:00:00Z`, `Tue, 30 Jun 2026 10:00:00 CST`, `Wed, 1 Jul 2026 09:00:00 KST` and `2026-12-01T00:00:00Z`, in any order
- **THEN** it returns them in the order January, June 30, July 1, December, and lists the June and July files as unreadable

##### Example: thread order with refused zones

| Dates given (any order) | Order returned | Listed as unreadable |
| --- | --- | --- |
| `2026-01-01T00:00:00Z`, `Tue, 30 Jun 2026 10:00:00 CST`, `Wed, 1 Jul 2026 09:00:00 KST`, `2026-12-01T00:00:00Z` | January, June 30, July 1, December | the June and July files |
| `garbage`, `2026-07-01T00:00:00Z` | `2026-07-01T00:00:00Z`, `garbage` | `garbage` |
| `Tue, 30 Jun 2026 10:00:00 -0000`, `2026-06-30T10:00:00Z` | equal keys; ties broken by file name | none |

##### Example: bounds ignore day-placed values

| Messages | `first_message` | `last_message` |
| --- | --- | --- |
| `Tue, 30 Jun 2026 10:00:00 CST`, `2026-07-01T00:00:00Z` | `2026-07-01T00:00:00Z` | `2026-07-01T00:00:00Z` |
| only `Tue, 30 Jun 2026 10:00:00 CST` | null | null |
