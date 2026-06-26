## 1. `search_emails` `summary` projection — 交付 spec 需求 "Search result projection and logical dedup"（design D3）

- [x] 1.1 RED：在 `Tests/CheAppleMailMCPTests/ServerSchemaTests.swift` 加 schema pin —— `search_emails` 的 `projection` 描述列出 `summary`；在 `Tests/MailSQLiteTests/` 加 FDA-gated `SummaryProjectionTests`（RED）：`projection: "summary"` 回 envelope，`results` 每元素剛好 `{id, date, sender, subject, mailbox}`（無 `to`/`cc`）、`limit+1` truncation、`dedup: "logical"` 折疊 mailbox 重複為 `MIN(ROWID)` 代表列
- [x] 1.2 [P] design D3 — `Sources/MailSQLite/EnvelopeIndexReader.swift`：實作 `summary` projection query —— 選 `id/date_received(ISO8601)/sender/subject/mailbox`、**不**做 recipient 子查詢、套用與 `ids` 相同的 `limit+1` truncation 與 `dedup: logical` 的 `GROUP BY`+`MIN(ROWID)`
- [x] 1.3 `Sources/CheAppleMailMCP/Server.swift`：`search_emails` handler 接 `summary` projection（走 reader）；`projection` schema enum 描述加 `summary`；`validateSearchProjection` 接受 `summary`、保持「非 `full` projection 需 SQLite index、否則 parameter error」與「`dedup: logical` + `full` 拒絕、但 `summary` 允許」規則（"Search result projection and logical dedup"）
- [x] 1.4 GREEN：1.1 的 schema pin 通過；FDA-gated reader 測試在有 index 時通過

## 2. `export_emails_markdown` → dedup-aware 歸檔原語

- [x] 2.1 RED：在 `Tests/CheAppleMailMCPTests/ExportEmailsMarkdownTests.swift` 加測試 —— 交付 "Markdown export manifest carries Message-ID"：manifest item 含 `message_id`；交付 "Markdown export Message-ID dedup skip-set"：給定 skip set 時命中 `message_id` 的候選 `status: "skipped"`（含 `id`/`message_id`）且不寫檔、manifest summary `skipped` 計數正確；空 skip set / 省略時行為與現狀一致（無 skipped item、`skipped` = 0）
- [x] 2.2 [P] design D2（"Markdown export manifest carries Message-ID"）— `Sources/CheAppleMailMCP/ExportEmailsMarkdown.swift`：`ExportManifestItem` 加 `message_id: String`（`jsonObject` 帶出）；`ExportManifest.jsonObject` 加 `skipped` 計數；`run(...)` 每筆 fetch 後把 `content.messageId`（無則 `""`）寫進 item
- [x] 2.3 design D1（"Markdown export Message-ID dedup skip-set"）— `Sources/CheAppleMailMCP/ExportEmailsMarkdown.swift`：`run(...)` 加 `skipMessageIds: Set<String> = []` 參數；對每個候選，若其 `message_id` 在集合內 → append `status:"skipped"` item、不呼叫寫檔路徑、不計入 `written`
- [x] 2.4 design D1（"Markdown export Message-ID dedup skip-set" — skip-set 輸入是檔案路徑）— `Sources/CheAppleMailMCP/Server.swift`：`export_emails_markdown` schema 加 optional `skip_message_ids_path`；handler 以 `AllowedRootsValidator`（唯讀，同 `output_dir` policy）驗證該路徑後讀檔 → parse（一行一個、忽略空行與 `#` 註解）成 `Set<String>` → 傳 `skipMessageIds` 進 `run`；缺檔／不可讀 → 空集合 + stderr note、不報錯；路徑越界 → write-safety 錯誤
- [x] 2.5 GREEN：2.1 全通過；`save_attachment` / 既有 export 呼叫端（無 `skip_message_ids_path`）行為不變

## 3. `get_emails_batch` Message-ID 對齊 — 交付 spec 需求 "Batch get emails Message-ID parity"（design D4）

- [x] 3.1 RED：在 `Tests/CheAppleMailMCPTests/ServerSchemaTests.swift`（或對應 handler 測試）加 pin —— `get_emails_batch` 每個 per-email result object 含 `message_id`（"Batch get emails Message-ID parity"）
- [x] 3.2 design D4 — `Sources/CheAppleMailMCP/Server.swift`：`get_emails_batch` 每封成功 result object 加 `"message_id": content.messageId`（無則 `""`）；per-email `error` 條目不變
- [x] 3.3 GREEN：3.1 通過

## 4. 收尾

- [x] 4.1 `CHANGELOG.md` `[Unreleased]`：Added/Changed 條目記三項加法（export `message_id` + `skip_message_ids_path` + `skipped`；search `summary` projection；batch `message_id`），引用 #177
- [x] 4.2 `swift build && swift test` 全綠（含新 schema pins、ExportEmailsMarkdown skip/message_id 測試；FDA-gated reader 測試在 CI 跳過）
- [x] 4.3 自檢：所有 spec scenario 有對應 task 覆蓋；無 `output_path`（延後）、無 `archive_emails` tool、無索引讀寫（Non-Goals 守住）
