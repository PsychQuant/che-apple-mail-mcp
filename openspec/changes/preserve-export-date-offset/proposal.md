## Problem

`batch_export_emails_markdown`（含 alias）寫出的 YAML frontmatter `date` 是 **UTC（`Z`）**，但同檔 body 的 `Date:` 行保留原始時區 offset。+8 使用者的實測（#244）：frontmatter `2026-07-13T08:49:57Z` vs body `Mon, 13 Jul 2026 16:49:57 +0800` — 差 8 小時。所有非 UTC 時區使用者 archive 的**每一封**信 frontmatter 時間戳都偏移；下游以 frontmatter 建的 index（threads/email_index）繼承同樣偏移；frontmatter 與 body 不一致本身是 data hygiene 問題。

## Root Cause

`EmailMarkdownRenderer.rfc822ToISO8601UTC`（EmailMarkdownRenderer.swift:119）：DateFormatter 把 RFC2822 zone token 消化成絕對時間後，輸出 formatter 硬 pin `TimeZone("UTC")` + `'Z'` 字尾 — 原始 offset 在 parse 後被丟棄。frontmatter（renderer :51）、manifest/index 路徑與 **filename 的 `YYYY-MM-DD`**（ExportEmailsMarkdown.swift:361-364 對同一輸出取 `prefix(10)`）三處共用此 helper。行為並非意外：batch-operations spec 的 frozen frontmatter contract 明文 `date` (ISO 8601 in UTC) — 所以本修復**必須**帶 MODIFIED spec delta（Spectra tier 的成因）。

## Proposed Solution

單點修 helper（更名 `rfc822ToISO8601`，呼叫點同步）：

1. Parse 絕對時間（現行 formats 不變）成功後，另從原字串抽 **numeric zone token**（regex `[+-]\d{4}`）→ 輸出 formatter 改用該固定 offset，格式 `yyyy-MM-dd'T'HH:mm:ssZZZZZ`（得 `+08:00`；offset 為零時 ZZZZZ 慣例輸出 `Z`，與現行 UTC 表示相容）
2. **Fallback 階梯**：zone 是 named form（`GMT`/`EST`…，RFC 5322 已不建議）或缺失 → 維持現行 UTC 輸出；date 整體不可解析 → 現行 passthrough 不變（leaf-path containment 的既有防護不動）
3. 三處輸出因共用 helper 自動一致：frontmatter `date`、manifest 排序/索引來源、filename 日期（`prefix(10)` 對 `+08:00` 格式同樣取到 `YYYY-MM-DD`，變為 **sender-local 日期** — 與 body `Date:` 行、與 spec「date is taken from the email's Date header」的語意一致化）

## Non-Goals

- **不回填歷史已匯出檔案**（append-only archive 慣例；混合 corpus 的說明寫入 CHANGELOG）
- **不改 manifest schema / frontmatter 欄位集**（值的格式變更，欄位不增減不重排）
- **不做雙欄位**（`date` + `date_utc`）— 增欄位違反 frozen contract 的最小變更原則，且 ISO-8601 with offset 已含絕對時間資訊，rejected alternative
- **不處理 body `Date:` 行**（本來就正確）

## Success Criteria

- `+0800` 信件：frontmatter `date: 2026-07-13T16:49:57+08:00`，filename 以 `2026-07-13`（sender-local）開頭，與 body `Date:` 一致
- UTC/缺 zone/named-zone 信件：輸出與現行位元相同（`Z`）
- 不可解析 date：passthrough 行為與現行相同（既有測試不變綠）
- 全套件 0 failures；spec delta 過 `spectra validate`

## Trade-offs（誠實記錄）

- **字串排序**：ISO-8601 with offset 在**混合 offset** corpus 做純字典排序時比較的是牆鐘時間、非絕對瞬間（`16:49+08:00` vs `09:00Z`）。單一使用者 archive 通常同 offset、排序不受影響；需要絕對序的消費者應 parse 後排序。使用者可讀性（#244 的直接痛點）優先於罕見的混合 offset 邊角 — 記入 CHANGELOG
- **Filename 跨午夜位移**：UTC 與 sender-local 日期不同的信件（跨午夜），re-export 會得到新 filename（舊檔不覆蓋）。Message-ID skip-set 去重不受影響（keyed on Message-ID 非 filename）；不用 skip-set 的裸 re-export 會出現雙檔 — 一次性、記入 CHANGELOG

## Impact

- Affected specs: `openspec/specs/batch-operations/spec.md`（MODIFIED: Server-side markdown export — frontmatter `date` 條款 + Filenames 條款 + 新 scenario）
- Affected code: `Sources/CheAppleMailMCP/EmailMarkdownRenderer.swift`（helper）、`Sources/CheAppleMailMCP/ExportEmailsMarkdown.swift`（呼叫點更名）、`Tests/CheAppleMailMCPTests/`（既有 pin `Z` 的測試更新 + 新 offset/fallback 測試）、`CHANGELOG.md`
- 併發批次 context：本 change 於 idd-all batch 內与 #248（docs）/#241/#242（compose 模組）零檔案交集（A_parallel_safe）
