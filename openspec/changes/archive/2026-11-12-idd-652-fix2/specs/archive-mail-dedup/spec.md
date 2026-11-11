## MODIFIED Requirements

### Requirement: Under last_archived, mail already in a top-level file is not rewritten

When `dedup_strategy` is `last_archived`, the `/archive-mail` SOP SHALL run `scan_report(output_dir)` once before Step 5, through `archived_set`, and SHALL treat the Message-IDs of its `usable` entries as already archived; files listed as `unparseable` or `synthetic_placeholder` SHALL add nothing. `archived_set` SHALL NOT raise: when the scan fails it SHALL return an empty set and the exception's type name (never its message), and the run SHALL continue. Step 4.1 SHALL add the set to `known_ids`, so a row whose usable Message-ID is in it is not new. In the same program, Step 4.1 SHALL call `write_skip_file` once per run, which never raises (on failure it returns no paths and the exception's type name, and the run goes on without a skip file or set file) and creates a new directory with `tempfile.mkdtemp` under the target's state directory (owner-only, not a predictable path) holding two files: the skip file for `skip_message_ids_path` (sorted, one id per line, leaving out every id the server's skip-file reader would read back differently: one holding CR or LF, one with leading or trailing characters of `HEADER_TRIM`, one starting with `#` or with a byte-order mark, or a blank one) and the full set as JSON for Step 5.1. The program SHALL print only paths and counts, never an id. Step 5.0 SHALL pass that skip file to every batch call; when a batch call is rejected because of `skip_message_ids_path`, it SHALL be sent once more without it, later batch calls of the run SHALL omit it, and Step 7 SHALL say so. Step 5.1 SHALL NOT put a Message-ID on a command line: it SHALL write a query file in the private directory holding `get_email`'s `message_id`, or, when that is empty, the name of a plain-text file with the mail#319 `get_email_headers` re-read, and SHALL skip the mail when `is_archived(set_file, query_file)` (two paths) returns `archived: true`. After Step 5, `remove_skip_dir(directory, state_dir)` SHALL delete the directory, refusing and deleting nothing when it is a symbolic link, is not directly under the state directory, or holds anything but the two regular files. Step 7 SHALL report how many mails were not rewritten for this reason, list the rows Step 4.1 left out (`archived_hits`, at most 20, id and bounded subject in a block labelled as data), report how many top-level files were scanned and how long the scan took, and name the gap when the scan failed. `index` and `both` SHALL be unchanged. A file moved out of the top level of `output_dir` is not seen, so its mail is archived again.

#### Scenario: A mail already archived is not new under last_archived

- **WHEN** `scan_report` lists a usable file with Message-ID `<a@x.test>` and Step 4.1 receives a row with that Message-ID dated after the boundary, under `last_archived`
- **THEN** the row is in neither `new_emails` nor `held_out`, and `archived_hits` returns it

##### Example: archived ids from a scan report

| `scan_report` result | Archived set |
| --- | --- |
| `usable` holds `<a@x.test>` and `<b@x.test>` | `{<a@x.test>, <b@x.test>}` |
| `usable` is empty; one file in `unparseable`, one in `synthetic_placeholder` | empty |
| `usable` entry whose `message_id` is `None` or blank | not added |
| not a dict | empty |

##### Example: a scan that cannot run

| `output_dir` | Archived set | `error` |
| --- | --- | --- |
| a regular file | empty | `NotADirectoryError` |
| a directory that does not exist | empty | none (nothing to scan) |
| any directory, when `scan_report` raises `RuntimeError` with mail text in its message | empty | `RuntimeError` (the message is not kept) |

##### Example: skip file contents

| Archived set | Skip file lines | Left out | Set file |
| --- | --- | --- | --- |
| `{<a@x.test>, <b@x.test>}` | `<a@x.test>`, `<b@x.test>` (sorted) | 0 | both ids |
| `{<a@x.test>, " <b@x.test>", "<c\nd@x.test>", "#e@x.test"}` | `<a@x.test>` | 3 | all four ids |
| empty | no lines | 0 | empty list |

##### Example: skip directory cleanup

| Directory | `remove_skip_dir` |
| --- | --- |
| a directory `write_skip_file` created, untouched | removes both files and the directory |
| the same, with one more file added | refuses (`ValueError`), deletes nothing |
| a directory not named `skip-ids-*` | refuses (`ValueError`) |
| a symbolic link named `skip-ids-*` in the state directory, pointing at a skip directory elsewhere | refuses; the target's files remain |
| a skip directory created under another directory | refuses; its files remain |

##### Example: rows decided with the archived set

| Row (strategy `last_archived`, boundary `2026-06-01T00:00:00Z`, archived `{<a@x.test>}`) | Result | Returned by `archived_hits` |
| --- | --- | --- |
| `<a@x.test>`, dated `2026-07-01T00:00:00Z` | neither | yes |
| `<a@x.test>`, dated `2026-05-01T00:00:00Z` | neither | no (before the boundary) |
| `<a@x.test>`, unreadable date | neither | yes |
| `<b@x.test>`, dated `2026-07-01T00:00:00Z` | `new_emails` | no |

##### Example: Step 5.1 check through a query file

| Query file | Set file holds `<a@x.test>` |
| --- | --- |
| `message_id` `<a@x.test>` | `{"has_message_id": true, "archived": true}` |
| `message_id` holding shell metacharacters that is in the set | `archived: true` (read as data) |
| `message_id` null, `headers_file` with `Message-ID: <a@x.test>` | `archived: true` |
| `message_id` null, `headers_file` without a Message-ID | `{"has_message_id": false, "archived": false}` |
| missing or unreadable | `{"has_message_id": false, "archived": false}` |
