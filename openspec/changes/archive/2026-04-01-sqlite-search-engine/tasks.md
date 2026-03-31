## 1. 專案設定與 SQLite 模組基礎

- [x] 1.1 修改 Package.swift，使用 C SQLite API 而非第三方 ORM：新增 sqlite3 system library target 或使用 bridging 方式讓 Swift 可以 import sqlite3（macOS 內建）
- [x] 1.2 建立 `Sources/CheAppleMailMCP/SQLite/` 目錄結構，新增獨立 SQLite 模組而非修改 MailController：建立 `EnvelopeIndexReader.swift` 和 `EmlxParser.swift` 空檔案

## 2. SQLite 連線與帳號對應

- [x] 2.1 實作 SQLite database connection management（SQLite 讀取策略：唯讀打開 + WAL 模式）：在 `EnvelopeIndexReader` 中使用 `sqlite3_open_v2` 以 `SQLITE_OPEN_READONLY` 開啟 Envelope Index。包含路徑常數定義（應對 [Risk] Envelope Index 路徑可能隨 macOS 版本變更）、路徑存在性檢查、以及 [Risk] Full Disk Access 權限不足時的清楚錯誤訊息
- [x] 2.2 實作 Mailbox URL decoding：解析 `mailboxes.url` 提取 account UUID 和 percent-decoded mailbox 名稱，處理 IMAP 和 EWS 兩種 URL 格式
- [x] 2.3 實作 Account UUID to name mapping（帳號 UUID 快取策略）：啟動時透過 AppleScript 查詢帳號名稱，配合 `~/Library/Mail/V10/` 目錄名稱建立 UUID → account name 的 `[String: String]` 映射，處理 Mailbox URL 與帳號名稱對應

## 3. SQLite 搜尋引擎

- [x] 3.1 實作 Envelope Index 查詢設計的核心 JOIN 結構：建立 prepared statement 將 messages、subjects、addresses、mailboxes 四表 JOIN，搜尋結果排除 deleted 訊息
- [x] 3.2 實作 Search emails by subject：使用 `subjects.subject LIKE` 進行 case-insensitive 主旨搜尋
- [x] 3.3 實作 Search emails by sender：匹配 `addresses.address` 和 `addresses.comment`（顯示名稱）
- [x] 3.4 實作 Search emails by recipient：透過 `recipients` JOIN 表搜尋 To (type=0) 和 CC (type=1) 收件人地址
- [x] 3.5 實作 Search with default field "any"：當 `field` 參數為 `any` 或省略時，同時搜尋 subject、sender、recipient
- [x] 3.6 實作 Date range filtering：支援 `date_from`/`date_to` 參數，將 ISO 8601 日期字串轉為 Unix timestamp 進行 `date_received BETWEEN` 過濾
- [x] 3.7 實作 Search result sorting and limiting：支援 `sort` (desc/asc) 和 `limit` (預設 50) 參數
- [x] 3.8 實作 Search result format backward compatibility：回傳 id、subject、sender、date_received、account_name、mailbox 欄位，新增 `to` 欄位包含主要收件人地址

## 4. .emlx 檔案解析

- [x] [P] 4.1 實作 Emlx file path resolution（.emlx 檔案定位）：從 message ROWID 和 mailbox URL 計算 `.emlx` 檔案路徑，處理 hash directory 結構（個位/十位/百位）、nested mailbox path、store UUID 子目錄掃描。處理 [Risk] .emlx 檔案可能被 Mail.app 刪除或移動：檢查檔案存在性，不存在時嘗試 `.partial.emlx`
- [x] [P] 4.2 實作 Emlx file format parsing（.emlx 檔案解析策略）：讀取第一行 byte count，提取 RFC 822 訊息資料，忽略尾部 Apple plist metadata
- [x] 4.3 實作 RFC 822 header parsing：解析 From、To、CC、Subject、Date、Content-Type 等 headers，處理 RFC 2047 encoded-word（Base64/Quoted-Printable）和 header line folding
- [x] 4.4 實作 MIME body parsing（處理 [Risk] MIME 解析複雜度）：根據 Content-Type 解析 body，支援 text/plain、text/html、multipart/* 遞迴解析、Content-Transfer-Encoding 解碼（Base64、Quoted-Printable）、以及非 UTF-8 charset 轉換（Big5、ISO-2022-JP 等）。無法解析的 MIME 結構 fallback 到 AppleScript
- [x] 4.5 實作 Get email content via emlx：整合 path resolution + format parsing + header/body parsing，提供完整的郵件內容讀取方法，包含 emlx 不可用時 fallback 到 AppleScript 的邏輯

## 5. 批次操作工具

- [x] [P] 5.1 實作 Batch get emails tool（批次操作設計）：在 `Server.swift` 註冊 `get_emails_batch` MCP 工具，接受 `emails` 陣列和 `format` 參數，使用 `TaskGroup` 並行透過 emlx reader 讀取，支援 partial failures
- [x] [P] 5.2 實作 Batch list attachments tool：在 `Server.swift` 註冊 `list_attachments_batch` MCP 工具，接受 `emails` 陣列，透過 AppleScript `listAttachments` 逐一查詢，支援 partial failures
- [x] 5.3 實作 Batch operation size limit：兩個批次工具均檢查陣列長度不超過 50，超過時回傳錯誤

## 6. 整合與接線

- [x] 6.1 在 `MailController` 中整合 `EnvelopeIndexReader`：讓 MailController 持有 EnvelopeIndexReader 實例，search_emails 改用 SQLite 後端，get_email 改用 emlx parser（含 fallback）。注意 [Trade-off] SQLite 查詢延遲 vs 資料新鮮度：WAL 模式下延遲極小，不需額外處理
- [x] 6.2 修改 `Server.swift` 中 `search_emails` 工具定義：新增 `field`、`recipient`、`date_from`、`date_to` 參數，更新工具描述
- [x] 6.3 修改 `Server.swift` 中 `search_emails` 路由邏輯：將新參數傳入 MailController 的 SQLite 搜尋方法
- [x] 6.4 修改 `Server.swift` 中 `get_email` 路由邏輯：優先使用 emlx parser，失敗時 fallback 到 AppleScript

## 7. 測試補全

- [x] [P] 7.1 Batch operation size limit 測試：驗證 `get_emails_batch` 和 `list_attachments_batch` 在陣列長度超過 50 時回傳 "Batch size exceeds maximum of 50 items" 錯誤（對應 spec: Batch operation size limit — Scenario: Batch size exceeds limit）。在 `Tests/MailSQLiteTests/BatchOperationTests.swift` 中建立測試，直接呼叫 `Server.executeToolCall` 或建構等效的參數驗證函式
- [x] [P] 7.2 Batch partial failure 測試：驗證 `get_emails_batch` 當部分郵件的 .emlx 不存在時，回傳成功的結果加上錯誤條目，不中斷整個 batch（對應 spec: Batch get emails tool — Scenario: Batch get with partial failures）
- [x] [P] 7.3 Batch empty request 測試：驗證 `get_emails_batch` 傳入空 `emails` 陣列時回傳空結果（對應 spec: Batch get emails tool — Scenario: Empty batch request）
- [x] 7.4 search_emails 新參數 E2E 測試：透過完整的 MCP tool call 路徑測試 `search_emails` 的 `field`、`date_from`、`date_to` 新參數是否正確傳遞到 SQLite 搜尋。在 `Tests/MailSQLiteTests/SearchIntegrationTests.swift` 中建立測試，使用真實 Envelope Index 驗證端到端結果
- [x] 7.5 get_email SQLite fallback 測試：驗證當 `EnvelopeIndexReader` 為 nil（SQLite 不可用）時，`get_email` 路由 fallback 到 AppleScript 路徑。驗證當 .emlx 檔案不存在時也 fallback 到 AppleScript
- [x] 7.6 刪除 `PlaceholderTests.swift`，確認全部測試通過且覆蓋率報告無未覆蓋的 public API
