## Why

`search_emails` / `list_emails` 走 SQLite fast path 時用 `... LIMIT ?`（`EnvelopeIndexReader.search` / `listEmails`），Server 直接 `return formatJSON(emails)` 回傳**裸 JSON array**。當底層命中數 ≥ `limit`，回傳剛好 `limit` 列、且沒有任何 row count / truncation metadata。呼叫端無法分辨「剛好 N 筆」與「N+ 筆被截到 N」——這是 **silent truncation**：任何「列舉 → 批次處理」的 consumer（特別是 `export_emails_markdown` #193 的大量歸檔流程）會在 prolific sender 超過 limit 時**無聲漏信**，operator 無從得知。

相關 issue：[#204](https://github.com/PsychQuant/che-apple-mail-mcp/issues/204)。同主題但不同 bug：#194（fallback 忽略 field/date filter）、#177（archive 大量歸檔 token 成本）。

## What Changes

- **`EnvelopeIndexReader.search` / `listEmails`**：內部抓 `limit + 1` 列，回傳前 `limit` 列 + 一個 `truncated` 旗標（`fetched > limit`）。`limit+1` 讓 truncation 偵測**確定性**（剛好 limit → 抓到 limit、`truncated=false`；更多 → 抓到 limit+1、`truncated=true`），免掉 `==limit` 偽陽性。回傳型別從裸陣列改為帶 `truncated` 的結果集。
- **`Server.swift` search_emails / list_emails dispatch**：response 從裸 array 改成 envelope `{ "results": [...], "returned": <int>, "limit": <int>, "truncated": <bool> }`（仍用既有 `formatJSON(_:)` 字串路徑，case 只是改傳 envelope 物件而非陣列）。AppleScript fallback 路徑也包同一 envelope（fallback 無法 `limit+1`，`truncated` 採 `returned == limit` 之 best-effort 啟發式並於描述標明）。
- **Tool descriptions**（search_emails / list_emails）：標明 envelope 形狀 + `truncated` 欄位語意 + 建議（命中 truncated 時調高 limit 或縮窄 query）。
- **Spec**：更新 `sqlite-query-engine` 的 limiting / result-format / list-emails requirement，新增 truncation envelope 契約。
- **Tests**：>limit → `truncated=true` 且 `returned==limit`；==limit → `truncated=false`；<limit → `truncated=false`；envelope 形狀含四個 key。

**Non-Goals**：offset/cursor 分頁與 `total_matched` 總數（需額外 COUNT 查詢）此 change 不做，列為 follow-up。Truncation 信號已足以讓呼叫端偵測並調整。

## Impact

**Affected code**：
- `Sources/MailSQLite/EnvelopeIndexReader.swift` — `search` / `listEmails` 的 `limit+1` 抓取 + truncation 旗標
- `Sources/CheAppleMailMCP/Server.swift` — search_emails / list_emails dispatch 的 envelope 組裝 + tool description
- `Tests/MailSQLiteTests/*` — truncation 偵測 + envelope 形狀測試
- `openspec/specs/sqlite-query-engine/spec.md` — archive 時併入

**Affected APIs（breaking shape change，已文件化）**：`search_emails` / `list_emails` 的 MCP response 從 bare array 變成 envelope object。每個 result element 的欄位不變（沿用 "Search result format backward compatibility"）。消費端（archive-mail skill、export 流程）需讀 `.results`。

**Affected systems**：`export_emails_markdown` 大量歸檔現在能偵測 truncation 並調整；任何依 search/list 列舉再批次處理的工作流。
