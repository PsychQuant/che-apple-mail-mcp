## Status

The evidence below describes PR #441 on its September 2026 base. On 2026-10-28 it was
re-integrated onto the current main as a local landing commit (not yet merged), and
the IDD ensemble ran on it (report on #374); see "Verify fixes" at the end.

As of 2026-09: implementation complete; full IDD ensemble pending Claude weekly quota recovery. No merge, deployment, archive migration, closure or verified tag.

## Contract evidence

SQLite fixtures assert integer 5=true and 0=false independently of mailbox names, including an All Mail draft copy and ordinary Projects/Drafts mail. NULL, unsupported integer/text values and absent type columns yield unknown. List, metadata, full and summary agree; logical dedup flags follow their selected MIN(ROWID), including groups with differing types. The six-field summary serializes true/false/null as valid JSON. IDs/count queries and shapes remain unchanged.

Injected AppleScript fallback tests exercise the actual list/search/metadata methods. They produce null and retain their existing one/one/five script-call counts, with no headers scripts added. A list-returning runner seam was added for this verification; production never sets it.

Export fixtures prove strict exclusion precedes body/attachment fetch, with draft skips and unknown/query-error items separately reported. Default false still writes and discloses the observed state. Duplicate input IDs retain their own per-iteration observations. Explicit null/non-boolean skip_drafts options are rejected.

## Commands

- `REGENERATE_MCPB_MANIFEST=1 swift test --filter 'DraftStatus|SearchProjection|SearchTruncation|ExportEmailsMarkdownTests|ManifestToolsSetEqualityTests'`: 95 tests, 0 failures; generated tool manifest synchronized.
- Final `swift test`: 1,239 tests, 10 skipped, 0 failures.
- Independent Codex static review: PASS, no blocking findings. The reviewer did not execute tests or establish live type semantics independently.
- `git diff --check` and Spectra validation passed. Only comment placement and evidence/task documentation changed after the full suite/review; runtime behavior did not change.

## Limits and adoption

Read-only local schema inspection confirmed type exists and that unsupported values also occur; no message content was read for that inspection. The 0/5 interpretation relies on the issue's supplied validation; other values deliberately remain unknown. The new functional tests use synthetic SQLite/content/script fixtures; broader existing tests retain their prior startup behavior.

Status is a read-time observation, not a shared snapshot with subsequent emlx reads or a stable logical message identity. Export adds a local SQLite status lookup per input, not headers MCP round-trips. Default export remains compatible and can include drafts; callers must request skip_drafts=true and handle unknown-state errors. Consumer adoption for plugins#127 is explicitly outside this API PR. Strict summary-field consumers must accept the added sixth field.

## Verify fixes (2026-10-28)

The ensemble found that type 0 is not evidence of a non-draft. A read-only count over
the maintainer's local Envelope Index (type, flags and mailbox only; no content)
showed many type-0 rows in the accounts' Drafts folders: drafts synced from a server
or another device. Most carried Mail's draft flag (0x40), which almost never appears
outside drafts; some had neither signal, and their only evidence was the folder they
are in. On the maintainer's decision, `is_draft` is now true on the type, the flag, or
either one on a copy sharing the global message id; false only without any of those
and outside drafts-named folders; null otherwise. The same count with the new rule
put every row in a drafts-named folder at true or null and none at false.

Draft exclusions now have their own status (`draft_skipped`) and count
(`drafts_skipped`), so `skipped` keeps meaning a Message-ID dedup hit; a failed
lookup names its cause; a misplaced `skip_drafts` or a non-object `opts` is rejected;
an uninspectable schema leaves the status unknown instead of taking the reader
offline.

## Verify round 2 (2026-10-28)

The second round found that the drafts-folder list was read once when the reader
opened, so a Drafts folder created or renamed while the server runs could still let
a draft be reported false; and that a missing flag or copy column, or a NULL value,
also produced false. Folder names are now judged on every query by a function
registered on the connection, and false needs every piece of evidence present and
negative. A read-only count over the maintainer's Envelope Index found no NULL type,
flag, global message id or mailbox url, so the stricter rule changes no real row.
Tests cover each case (missing columns, NULL values, an unknown folder name, a missing
mailbox row, a folder created and one renamed after open); seven mutations were each
caught. `opts: null` now means absent; the export writes one stderr line for the first
failed status lookup and one count, not a line per id.

