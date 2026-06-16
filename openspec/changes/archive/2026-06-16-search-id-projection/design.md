# Design — search-id-projection

## D1. Why projection lives at the reader, not just the JSON layer

The naïve fix is "format only `id` in the handler". That shrinks the wire payload but keeps the **per-row `fetchRecipients` subquery** (`EnvelopeIndexReader.swift:593`) — the `to` field is fetched for every row even though it's discarded. So an N-row search stays N+1 queries. The real win requires a **separate light query** (`searchIds`) that never touches the `recipients` table for output and never projects subject/address columns. Hence reader-level methods, not handler-level filtering.

## D2. Three reader methods, not a polymorphic return

`projection` changes the *return shape*, and Swift methods can't return different types from one signature cleanly. So the handler dispatches to one of three reader methods:

| projection | reader method | returns |
|---|---|---|
| `full` (default) | `searchPage` (existing) | `(results: [SearchResult], truncated: Bool)` |
| `ids` | `searchIds(_:dedup:)` (new) | `(ids: [Int], truncated: Bool)` |
| `count` | `searchCount(_:dedup:)` (new) | `Int` |

All three share a single `buildSearchConditions(_:) -> (conditions, bindings)` helper extracted from `searchPage`'s WHERE assembly (field switch + date + account + mailbox). The field/date/account/mailbox semantics stay identical across projections — only the SELECT/GROUP/output differ. This keeps the four search-field branches (subject/sender/recipient/any) defined once.

## D3. Logical dedup is server-side `GROUP BY`, keyed on index-available columns

Gmail surfaces each logical email ~3× (`INBOX` / `Archive` / `[Gmail]/All Mail`) as distinct ROWIDs sharing `(subject, sender address, date_received)`. The Envelope Index has **no queryable RFC Message-ID** (it lives in the `.emlx`; `export_emails_markdown` reads it per-file). So the only cheap, pure-SQL dedup key is the index tuple `(s.subject, a.address, m.date_received)`.

`dedup: "logical"` adds `GROUP BY s.subject, a.address, m.date_received` and selects `MIN(m.ROWID)` — one representative copy per logical email. For export the content is identical across copies, so `MIN` is a deterministic, sufficient choice. `ORDER BY m.date_received` stays valid because `date_received` is part of the group key (one value per group).

**Heuristic honesty**: two genuinely-distinct emails that share subject + sender + exact receive-second would collapse (rare). This is documented; dedup is **opt-in** so the default search is never silently deduped.

## D4. `count` ignores `limit`; `ids`/`full` honor it

`projection: "count"` answers "how big is this backlog?" — it returns the **total** match count and does **not** bind `limit` (no `LIMIT` clause; dedup → `COUNT(*)` over the grouped subquery). `ids` and `full` keep the #204 `limit + 1` definitive-truncation contract: fetch up to `limit + 1`, return at most `limit`, `truncated = fetched > limit`. For `ids` + `dedup`, truncation counts **groups** (logical emails), not raw rows — consistent with what the caller receives.

## D5. Param validation + SQLite-only

- `projection` ∈ {`full`,`ids`,`count`} — else `invalidParameter`.
- `dedup` ∈ {`none`,`logical`} — else `invalidParameter`.
- `dedup: "logical"` with `projection: "full"` → `invalidParameter` (full-row dedup is a Non-Goal; reject rather than silently ignore).
- `projection` ≠ `full` requires the SQLite index. The AppleScript fallback cannot cheaply produce id-only / count results, so when `indexReader == nil` and `projection ≠ full`, throw `invalidParameter("projection \"…\" requires the SQLite envelope index, which is unavailable")`. No silent degrade.

## D6. Backward compatibility (the hard constraint)

Omitting `projection`/`dedup` MUST be byte-identical to today: `searchPage` → `resultEnvelope(results, limit, truncated)` with every per-result field unchanged. New params are additive optionals; existing callers and the full existing test suite are untouched. This is verified by a backward-compat test asserting the default path still emits the four-key envelope with full result objects.

## D7. Why not fused server-side search→export (issue Direction 3) now

Letting `export_emails_markdown` accept a search spec would eliminate even the small id round-trip, but it's a much larger surface (a search engine inside the export tool, dedup semantics, direction labelling, its own `batch-operations` spec changes) and isn't needed to unblock the archive flow. The `projection=ids&dedup=logical` → `export_emails_markdown(ids)` two-step already reduces the collection payload by ~10–30× and removes the N+1 subqueries. Direction 3 stays a tracked follow-up (issue Residue).
