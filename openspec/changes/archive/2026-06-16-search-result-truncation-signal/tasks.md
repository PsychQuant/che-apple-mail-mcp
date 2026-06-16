## 1. EnvelopeIndexReader — 確定性 truncation 偵測（D1）

- [x] 1.1 `search(_:)`：SQL `LIMIT ?` 綁 `params.limit + 1`，收集後若 `count > limit` 則 `truncated = true` 並只保留前 `limit` 列。回傳 `(results, truncated)`（新型別或 tuple）。
- [x] 1.2 `listEmails(...)`：同樣 `LIMIT ?` 綁 `limit + 1` + 前 `limit` 列 + `truncated`。
- [x] 1.3 確認所有 search field 分支（subject/sender/recipient/any）共用同一 SQL 組裝點，`limit+1` 單點覆蓋全部。

## 2. Server dispatch — envelope（D2/D3）

- [x] 2.1 `search_emails` SQLite 路徑：`return formatJSON(envelope)`，envelope = `{ results: [...], returned: N, limit: L, truncated: Bool }`。
- [x] 2.2 `list_emails` SQLite 路徑：同上 envelope。
- [x] 2.3 兩者的 AppleScript fallback 路徑：包同一 envelope，`truncated` 採 `returned == limit` best-effort（D3）。
- [x] 2.4 更新 `search_emails` / `list_emails` tool description：標明 envelope 形狀、`truncated` 語意、命中 truncated 時的建議（調高 limit / 縮窄 query）；fallback 的 truncated 為啟發式。

## 3. Tests

- [x] 3.1 `search` >limit → `truncated=true` 且 `returned==limit`（fixture 造 ≥ limit+1 列）。
- [x] 3.2 `search` ==limit → `truncated=false`（剛好 limit 列不偽陽性）。
- [x] 3.3 `search` <limit → `truncated=false`。
- [x] 3.4 `listEmails` 三種 truncation case 同上。
- [x] 3.5 Server envelope 形狀測試：response 含 `results`/`returned`/`limit`/`truncated` 四個 key，`results` 為陣列、每個 element 仍含既有欄位。

## 4. Spec + build verify

- [~] 4.1 `openspec/specs/sqlite-query-engine/spec.md` 由 change 的 spec delta 於 archive 時併入（spectra 處理） — 由 spectra archive 於 merge 後併入 canonical spec（deferred 到 archive 時）。
- [x] 4.2 `swift build` 通過、`swift test` 全綠（既有測試零 regression + 新增測試通過）。
- [x] 4.3 `spectra validate search-result-truncation-signal` 通過。
