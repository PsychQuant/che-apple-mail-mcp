## Why

大量歸檔（#177）付出 **O(corpus) 的 token 成本**：`search_emails` 把每筆 hit 的完整 JSON inline 回傳，`get_emails_batch` 把每封信內容拉進 LLM context 才寫出——內容兩次流經 context window（MCP 回傳 → 寫檔）。2026-06-11 實測 97 封歸檔 inline 了 ~200 筆完整搜尋結果與 ~1.1MB batch 內容；大 corpus 回填實務上不可行，長 session 也容易被擠向 compaction。

關鍵觀察：**binary-side 寫檔路徑大部分已經 ship**。`search_emails projection: ids`（既有 `projection` enum）→ `export_emails_markdown` 已經能 **binary-side 零內容進 context** 地寫 markdown（YAML frontmatter + 檔名規則）並回一份小 manifest。剩下的 gap 很窄：manifest 不帶 `message_id`（下游歸檔器無法只靠 manifest 維護 Message-ID 索引、被迫重抓）、`export_emails_markdown` 無法**跳過已歸檔**信件（re-run 全部重寫）、`ids` 與 `full` 之間缺一個輕量 **triage** projection、`get_emails_batch` 缺 `message_id`（dedup 被迫用 synthetic key）。補齊這些，就把既有 composition 變成一個完整、**dedup-aware**、O(1)-context 的歸檔原語——**不需**新的 monolithic `archive_emails` tool，binary 也**不擁有**任何歸檔索引格式。

## What Changes

- `export_emails_markdown` 成為 **dedup-aware 歸檔原語**：每個 manifest item 補 `message_id`；tool 接受 optional「已歸檔 Message-ID 集合」並**跳過**命中者（manifest 回 `skipped` 計數 + 被跳過的 id/message_id），所以 re-run 只寫新信。內容永不進 context。
- `search_emails` 的既有 `projection` enum 新增 `summary` 值，回 triage 形狀（只有 `id` / `date` / `sender` / `subject` / `mailbox`）——介於 `ids`（人工 triage 太稀疏）與 `full`（O(corpus) 成本）之間。
- `get_emails_batch` 每個 per-email result object 補 `message_id`（與單封 `get_email` 對齊），讓直接用 batch 的呼叫端能對 canonical Message-ID 索引做 dedup。

下游歸檔**索引**（`email_index.json` / `threads.json`）維持是呼叫端／skill 的 contract——MCP server 只提供原語，不當有主見的索引擁有者。

## Non-Goals

- **不做新的 `archive_emails` tool。** 補強過的 search→export composition 已涵蓋 token win；monolithic tool 會重複既 ship 的邏輯，還逼 binary 永久擁有某種 per-workflow 索引格式。
- **binary 不讀／不寫／不定義 `email_index.json` / `threads.json`。** dedup 由呼叫端提供的 Message-ID 集合驅動；索引維護留在呼叫端／skill。
- **`get_emails_batch` 的 `output_path`（issue direction 3）延後**——歸檔場景已被 `export_emails_markdown` 路徑取代；只有出現「raw JSON 落地」需求時才重啟。
- **不改 markdown／frontmatter／檔名格式**（由既有 `export_emails_markdown` contract 凍結）。
- **不改 content 全文掃描禁令（#221）** 與 validate→write 安全模型（#197/#200）。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `batch-operations`：`export_emails_markdown` 新增 per-item `message_id` 欄位 + optional 已歸檔-Message-ID skip-set 輸入與 `skipped` 回報；`get_emails_batch` 新增 per-email `message_id` 欄位。
- `sqlite-query-engine`：`search_emails` 的 `projection` enum 新增 `summary` 值（triage 欄位）。

## Impact

- Affected specs：`batch-operations`、`sqlite-query-engine`（requirement-level：新欄位 + 新 projection enum 值 + skip/dedup contract）。
- Affected code：
  - `Sources/CheAppleMailMCP/Server.swift` —— `export_emails_markdown` schema（skip-set 參數）+ handler wiring；`search_emails` `projection` enum（`summary`）+ handler；`get_emails_batch` result object（`message_id`）。
  - `Sources/CheAppleMailMCP/ExportEmailsMarkdown.swift` —— manifest item 加 `message_id`；per-message 寫檔前套用 skip-set（跳過 + 回報）。
  - `Sources/MailSQLite/EnvelopeIndexReader.swift` —— search 路徑的 `summary` projection query／形狀；export skip/manifest 需要的 `message_id` 取得。
  - Tests：schema pins（新欄位／projection 值）、`ExportEmailsMarkdown` skip + manifest `message_id`（純邏輯走 default suite）、reader `summary` projection（FDA-gated `MailSQLiteTests`）。
