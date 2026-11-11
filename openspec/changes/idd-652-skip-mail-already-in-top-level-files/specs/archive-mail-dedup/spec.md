## ADDED Requirements

### Requirement: Under last_archived, mail already in a top-level file is not rewritten

When `dedup_strategy` is `last_archived`, the `/archive-mail` SOP SHALL run `scan_report(output_dir)` once before Step 5 and SHALL treat the Message-IDs of its `usable` entries as already archived; files listed as `unparseable` or `synthetic_placeholder` SHALL add nothing. Step 4.1 SHALL add that set to `known_ids`, so a row whose usable Message-ID is in it is not new. Step 5.0 SHALL pass the set as `skip_message_ids_path`, written one id per line into a new directory created with `tempfile.mkdtemp` under the target's state directory (owner-only, not a predictable path); an id that the server would read back differently (one holding CR or LF, one with leading or trailing spaces or tabs, one starting with `#`, or a blank one) SHALL be left out of the file. Step 5.1 SHALL skip a mail whose `get_email` `message_id` is in the set. Step 7 SHALL report how many mails were not rewritten for this reason, how many top-level files were scanned and how long the scan took; when the scan could not run, Step 7 SHALL say so and the run SHALL continue with an empty set. `index` and `both` SHALL be unchanged. A file moved out of the top level of `output_dir` is not seen, so its mail is archived again.

#### Scenario: A mail already archived is not new under last_archived

- **WHEN** `scan_report` lists a usable file with Message-ID `<a@x.test>` and Step 4.1 receives a row with that Message-ID dated after the boundary, under `last_archived`
- **THEN** the row is in neither `new_emails` nor `held_out`, and `count_archived_hits` counts it

##### Example: archived ids from a scan report

| `scan_report` result | Archived set |
| --- | --- |
| `usable` holds `<a@x.test>` and `<b@x.test>` | `{<a@x.test>, <b@x.test>}` |
| `usable` is empty; one file in `unparseable`, one in `synthetic_placeholder` | empty |
| `usable` entry whose `message_id` is `None` or blank | not added |
| not a dict | empty |

##### Example: skip file contents

| Archived set | File lines | Left out |
| --- | --- | --- |
| `{<a@x.test>, <b@x.test>}` | `<a@x.test>`, `<b@x.test>` (sorted) | 0 |
| `{<a@x.test>, " <b@x.test>", "<c\nd@x.test>", "#e@x.test"}` | `<a@x.test>` | 3 |
| empty | no lines | 0 |

##### Example: rows decided with the archived set

| Row (strategy `last_archived`, boundary `2026-06-01T00:00:00Z`, archived `{<a@x.test>}`) | Result | Counted as an archived hit |
| --- | --- | --- |
| `<a@x.test>`, dated `2026-07-01T00:00:00Z` | neither | yes |
| `<a@x.test>`, dated `2026-05-01T00:00:00Z` | neither | no (before the boundary) |
| `<a@x.test>`, unreadable date | neither | yes |
| `<b@x.test>`, dated `2026-07-01T00:00:00Z` | `new_emails` | no |
