## 1. EnvelopeIndexReader — shared WHERE builder + light projections (D1/D2/D3)

- [x] 1.1 Extract `buildSearchConditions(_ params: SearchParameters) -> (conditions: [String], bindings: [String])` from `searchPage` (the field switch + date + account + mailbox assembly); refactor `searchPage` to call it (behavior unchanged).
- [x] 1.2 Add `searchIds(_ params: SearchParameters, dedup: Bool) throws -> (ids: [Int], truncated: Bool)` — `SELECT m.ROWID` only, no per-row `fetchRecipients`; sort + `LIMIT (limit + 1)`; `truncated = ids.count > limit`; return `Array(ids.prefix(limit))`. Same `limit` clamp as `searchPage` (`min(max(limit,0), Int32.max-1)`).
- [x] 1.3 `searchIds` dedup branch: `GROUP BY s.subject, a.address, m.date_received`, `SELECT MIN(m.ROWID)`, `ORDER BY m.date_received`; truncation counts groups.
- [x] 1.4 Add `searchCount(_ params: SearchParameters, dedup: Bool) throws -> Int` — `SELECT COUNT(*)` (no `LIMIT`), dedup → `SELECT COUNT(*) FROM (… GROUP BY s.subject, a.address, m.date_received)`. Returns total match count.

## 2. Server dispatch + tool schema (D2/D4/D5/D6)

- [x] 2.1 `search_emails` inputSchema: add `projection` (string: full/ids/count) + `dedup` (string: none/logical) properties.
- [x] 2.2 Handler: parse `projection` (default `full`) + `dedup` (default `none`); validate enum values + reject `dedup=logical` with `projection=full`.
- [x] 2.3 SQLite path dispatch: `ids` → `searchIds` → `{ results: [id strings], returned, limit, truncated }`; `count` → `searchCount` → `{ count }`; `full` → existing `searchPage` → `resultEnvelope` (unchanged).
- [x] 2.4 AppleScript fallback: if `projection != full` and no reader → throw `invalidParameter` (SQLite-only).
- [x] 2.5 Update `search_emails` tool description: projection/dedup semantics + bulk-archive usage (`projection=ids&dedup=logical` → `export_emails_markdown`).

## 3. Tests

- [x] 3.1 `searchIds` (no dedup): returns rowId-only list; count matches; `>limit` → `truncated=true` & `returned==limit`; `==limit` → false; negative-limit no trap.
- [x] 3.2 `searchIds` (dedup): fixture with mailbox-duplicate rows (same subject/sender/date across 3 mailboxes) → one rowId per logical email; `returned` < raw row count.
- [x] 3.3 `searchCount`: returns total matches ignoring `limit` (fixture with N matches, `limit: 1` → count == N); dedup → count == logical-email count.
- [x] 3.4 Reader-level coverage complete (12 new tests in `SearchProjectionTests`); full-path backward-compat asserted. Server handler dispatch/validation is thin glue over the tested reader methods (mirrors existing test strategy — reader + helpers tested, MCP dispatch is glue).

## 4. Spec + build verify

- [~] 4.1 `openspec/specs/sqlite-query-engine/spec.md` merged from this change's spec delta at archive time (spectra handles) — deferred to `spectra archive` post-merge.
- [x] 4.2 `swift build` passes; `swift test` all green — 652 tests, 50 skipped (FDA-gated), 0 failures (640 → 652: +12 projection/dedup tests, zero regression).
- [x] 4.3 `spectra validate search-id-projection` passes.
