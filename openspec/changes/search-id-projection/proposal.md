## Why

`search_emails` 走 SQLite fast path 時，對每個命中都序列化**完整** `SearchResult`（`id` / `subject` / `sender` / `date_received` / `account_name` / `account_id` / `mailbox` / `isRead` / `isFlagged` / `to`），而且 `searchPage` 在 row loop 內**逐列**呼叫 `fetchRecipients`（per-row 子查詢）來填 `to` 欄位 —— N 列命中 = **N+1 次 SQLite 查詢** + 肥大 payload。

對大量歸檔流程（`export_emails_markdown` #193）而言，呼叫端**只需要 rowId** 餵回 export，卻被迫把整個結果集搬回 client。實測：單一 `search_emails(query="peng.cyj@gmail.com", field="any", date_to="2025-12-31", limit=400)` 回 **400 列 = 109,212 字元 / 3,207 行**，超過 agent token 上限被迫存檔。Gmail 每封信在 `INBOX` / `Archive` / `All Mail` 重複出現 ~3×，payload 再乘三。結果就是「明明用程式卻超久」—— 瓶頸不是查詢（毫秒級），是把幾千列完整 row 搬回 client 只為了抽 rowId。

相關 issue：[#208](https://github.com/PsychQuant/che-apple-mail-mcp/issues/208)。relates #204（truncation envelope —— 為避開 `truncated` 而調高 `limit` 反而放大 payload）、#193（`export_emails_markdown` —— 這個投餵對象）。

## What Changes

- **`EnvelopeIndexReader`**：抽出共用的 WHERE-clause builder（field / date / account / mailbox 條件 + bindings），讓 `searchPage` 與下列新方法共用單一組裝點。
  - 新增 `searchIds(_:dedup:)` —— **只 `SELECT m.ROWID`**，不做 subject/address 投影、**不**呼叫 per-row `fetchRecipients`；沿用 #204 的 `limit + 1` 確定性 truncation。回 `(ids, truncated)`。
  - 新增 `searchCount(_:dedup:)` —— `SELECT COUNT(*)`（dedup 時 `COUNT(*)` over a grouped subquery），**忽略 `limit`**，回**總命中數**供 scoping。
  - `dedup == true`（logical）時兩者都用 `GROUP BY s.subject, a.address, m.date_received` 在 **server 端** collapse mailbox 重複，每個 logical email 只回一個代表 rowId（`MIN(m.ROWID)`）。Pure SQL，不讀 `.emlx`。
- **`search_emails` tool**：新增兩個 optional param：
  - `projection`：`full`（預設）/ `ids` / `count`。
    - `full` → 既有 envelope `{ results, returned, limit, truncated }`（**完全不變**）。
    - `ids` → `{ results: [<id>…], returned, limit, truncated }`，`results` 為 rowId 字串陣列。
    - `count` → `{ count: <int> }`（總命中數，不套 `limit`）。
  - `dedup`：`none`（預設）/ `logical`。只能搭配 `projection` 為 `ids` 或 `count`（搭 `full` 報 `invalidParameter`）。
  - projection 為 `ids`/`count` 屬 **SQLite-only**：index 不可用時報 `invalidParameter`（不靜默退化）。
- **Tool description** 標明 projection / dedup 語意 + bulk-archive 用法（`projection=ids&dedup=logical` → 小而去重的 id list → `export_emails_markdown`）。
- **Spec**：更新 `sqlite-query-engine`，新增 projection/dedup 契約、註明 truncation envelope 的 ids 變體。
- **Tests**：ids 形狀 + 只回 id；count 回總數（忽略 limit）；dedup collapse 正確（mailbox 重複只回一筆）；ids 路徑沿用 limit+1 truncation；`dedup=logical` + `projection=full` 報錯；省略 param → 與既有 full envelope byte-identical。

**Non-Goals**：full-row 的 logical dedup、`export_emails_markdown` 接受 search-spec（fused server-side search→export，issue Direction 3）此 change **不做**，列 follow-up（見 issue Residue）。RFC Message-ID 級別的 dedup（需逐封讀 `.emlx`）**不做** —— projection dedup 用 index-available 的 `(subject, sender, date_received)` heuristic。

## Impact

**Affected code**：
- `Sources/MailSQLite/EnvelopeIndexReader.swift` — 抽出 WHERE builder + `searchIds` / `searchCount`
- `Sources/CheAppleMailMCP/Server.swift` — `search_emails` inputSchema（`projection` / `dedup`）+ dispatch
- `Tests/MailSQLiteTests/*`、`Tests/CheAppleMailMCPTests/*` — projection / dedup / backward-compat 測試
- `openspec/specs/sqlite-query-engine/spec.md` — archive 時併入

**Affected APIs（additive，backward-compatible）**：`search_emails` 新增 optional `projection` / `dedup`。**省略時行為 byte-identical**（`full` envelope + 每個 result 欄位不變）。既有 callers / tests 不受影響。

**Affected systems**：`archive-mail` 大量歸檔可改用 `projection=ids&dedup=logical` 一次拿到小而去重的 rowId list 直接餵 `export_emails_markdown`，免把整個結果集搬回 client。
