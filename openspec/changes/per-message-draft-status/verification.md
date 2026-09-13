## Status

Implementation complete; full IDD ensemble pending Claude weekly quota recovery. No merge, deployment, archive migration, closure or verified tag.

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
