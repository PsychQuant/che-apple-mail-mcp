## Context

che-apple-mail-mcp 目前所有讀取操作都透過 AppleScript bridge 與 Mail.app 互動。此架構在 25 萬封郵件的環境下效能極差：跨帳號搜尋需遍歷每個 mailbox、搜尋只支援 sender + subject、且 Swift actor 序列化導致多個 MCP 呼叫無法並行。

macOS Mail.app 已將所有郵件索引存入 SQLite 資料庫 `~/Library/Mail/V10/MailData/Envelope Index`，且郵件內容以 `.emlx` 檔案（RFC 822 + Apple plist metadata）存放於 `~/Library/Mail/V10/<AccountUUID>/` 目錄下。

現有程式碼結構：
- `MailController` 是一個 Swift `actor`，包含所有 AppleScript 操作
- `Server.swift` 定義所有 MCP tool 並路由到 `MailController` 方法
- AppleScript message `id` 與 SQLite `messages.ROWID` 直接對應，無需 ID 轉換

## Goals / Non-Goals

**Goals:**

- 搜尋速度從秒級降至毫秒級（SQLite indexed queries）
- 支援 recipient (to/cc) 搜尋、日期範圍過濾
- 新增 `get_emails_batch`、`list_attachments_batch` 批次工具
- 透過 `.emlx` 解析取得郵件內容，繞過 AppleScript `content of message`
- 保持 AppleScript ID 相容性：SQLite 查詢結果可直接用於現有寫入操作

**Non-Goals:**

- 不修改任何 AppleScript 寫入操作（compose、reply、forward、move、delete）
- 不寫入 SQLite 資料庫
- 不實作 IMAP 直連
- 不取代 AppleScript 用於附件下載（`save attachment` 仍需 AppleScript）

## Decisions

### SQLite 讀取策略：唯讀打開 + WAL 模式

使用 `sqlite3_open_v2` 以 `SQLITE_OPEN_READONLY` 模式打開 Envelope Index，避免任何意外寫入或鎖衝突。Mail.app 使用 WAL (Write-Ahead Logging) 模式，讀取時不會阻塞 Mail.app 的寫入操作。

**替代方案**：複製資料庫再查詢 — 複製 250MB+ 檔案的開銷太大，且複製瞬間的快照可能不一致。

### 新增獨立 SQLite 模組而非修改 MailController

新增 `Sources/CheAppleMailMCP/SQLite/` 目錄，包含兩個檔案：
- `EnvelopeIndexReader.swift` — SQLite 查詢層
- `EmlxParser.swift` — .emlx 檔案解析

`EnvelopeIndexReader` 作為一個獨立的 `class`（非 actor），因為 SQLite readonly 連線本身是線程安全的（WAL 模式下多個 reader 可並行），不需要 actor 的序列化。`MailController` 會持有一個 `EnvelopeIndexReader` 實例，讀取操作委派給它，寫入操作繼續使用 AppleScript。

**替代方案**：直接在 `MailController` 內加入 SQLite 程式碼 — 會讓 actor 更臃腫，且 SQLite 操作不需要 actor 序列化。

### 使用 C SQLite API 而非第三方 ORM

直接使用 macOS 內建的 `libsqlite3`（透過 `CSQLite` system module 或直接 import），不引入 GRDB、SQLite.swift 等第三方依賴。原因：
1. 查詢固定（少量 prepared statements），不需要 query builder
2. 減少依賴、減少編譯時間
3. `Package.swift` 只需加一個 system library target

**Package.swift 變更**：新增 `systemLibrary` target 包裹 `sqlite3`，或直接使用 `#if canImport(SQLite3)` / bridging header。macOS 13+ 保證有 sqlite3。

### Envelope Index 查詢設計

核心 JOIN 結構：
```sql
SELECT m.ROWID, s.subject, a.address, a.comment,
       m.date_received, m.read, m.flagged, mb.url
FROM messages m
JOIN subjects s ON m.subject = s.ROWID
JOIN addresses a ON m.sender = a.ROWID
JOIN mailboxes mb ON m.mailbox = mb.ROWID
WHERE m.deleted = 0
```

搜尋過濾條件組合：
- **Subject 搜尋**：`s.subject LIKE '%query%'`（subjects 表有 RTRIM collation）
- **Sender 搜尋**：`a.address LIKE '%query%' OR a.comment LIKE '%query%'`
- **Recipient 搜尋**：子查詢 `EXISTS (SELECT 1 FROM recipients r JOIN addresses ra ON r.address = ra.ROWID WHERE r.message = m.ROWID AND (ra.address LIKE '%query%' OR ra.comment LIKE '%query%'))`
- **日期範圍**：`m.date_received BETWEEN ? AND ?`（Unix timestamp）
- **Mailbox 過濾**：`mb.url LIKE '%<encoded-path>%'`
- **帳號過濾**：`mb.url LIKE '<protocol>://<account-uuid>/%'`

recipients 表的 `type` 欄位：0 = To, 1 = CC。

### Mailbox URL 與帳號名稱對應

Envelope Index 的 `mailboxes.url` 格式為 `imap://<ACCOUNT-UUID>/<URL-encoded-path>` 或 `ews://<ACCOUNT-UUID>/<URL-encoded-path>`。需要建立帳號 UUID → 帳號名稱的對應關係。

方案：啟動時用 AppleScript 取得帳號清單（包含名稱），配合 `~/Library/Mail/V10/` 下的目錄名稱（就是 Account UUID）和各帳號的 `Info.plist` 取得對應。或者直接使用 AppleScript 取一次 account name + account id 的 mapping，快取在記憶體中。

### .emlx 檔案解析策略

`.emlx` 格式：
1. 第一行：郵件資料的 byte count（整數字串）
2. 接下來是標準 RFC 822 郵件（headers + body）
3. 郵件內容結束後是 Apple plist metadata（XML 格式）

解析步驟：
1. 讀取第一行取得 byte count
2. 讀取 byte count 長度的資料作為 RFC 822 郵件
3. 解析 headers（From, To, CC, Subject, Date, Content-Type 等）
4. 根據 Content-Type 解析 body：
   - `text/plain`：直接取文字
   - `text/html`：取 HTML
   - `multipart/*`：遞迴解析 MIME boundaries 取得 text 和 html parts

檔案路徑定位：`~/Library/Mail/V10/<Account-UUID>/<MailboxPath>.mbox/<StoreUUID>/Data/<hash-dirs>/Messages/<ROWID>.emlx`。hash-dirs 是 ROWID 的 hash 分散路徑（個位數/十位數/百位數）。

**替代方案**：使用 `searchable_messages` 表取內容 — 但該表的 content 欄位不完整，僅用於 Spotlight 索引，不含完整 HTML。

### .emlx 檔案定位

從 SQLite `messages.ROWID` 和 `mailboxes.url` 推算 `.emlx` 路徑：

1. 從 `mailboxes.url` 提取 account UUID 和 mailbox 路徑
2. 基礎路徑：`~/Library/Mail/V10/<account-uuid>/`
3. Mailbox 路徑映射：URL-decode mailbox 路徑，各層加 `.mbox` 後綴
4. 在 mailbox 目錄下找到唯一的 store UUID 子目錄
5. 計算 hash 目錄：ROWID 的各位數字反向作為子目錄（例如 ROWID=267597 → `7/9/5/Messages/267597.emlx`）
6. 如果 `.emlx` 不存在，嘗試 `.partial.emlx`（部分下載的郵件）

### 批次操作設計

新增兩個 MCP 工具：
- `get_emails_batch`：接受 `ids` 陣列（每個含 id/mailbox/account_name），回傳多封郵件內容
- `list_attachments_batch`：接受 `ids` 陣列，回傳多封郵件的附件清單

批次工具在內部使用 `TaskGroup` 並行處理，但附件相關操作仍需透過 AppleScript（附件路徑由 Mail.app 管理），所以 `list_attachments_batch` 的並行度受限於 MailController actor。

`get_emails_batch` 可完全使用 SQLite + .emlx，不經過 actor，實現真正的並行讀取。

### search_emails 改用 SQLite 後端

`search_emails` MCP 工具改用 `EnvelopeIndexReader` 進行搜尋。新增參數：
- `recipient`：搜尋收件人地址（to/cc）
- `date_from` / `date_to`：日期範圍過濾（ISO 8601 格式）
- `field`：指定搜尋欄位（`subject`、`sender`、`recipient`、`any`），預設 `any`

回傳格式維持向後相容（id、subject、sender、date_received、account_name、mailbox），額外增加 `to` 欄位。

### 帳號 UUID 快取策略

在 `EnvelopeIndexReader` 初始化時，掃描 `~/Library/Mail/V10/` 下的目錄結構，建立帳號 UUID → 帳號名稱的映射。做法：
1. 列舉 `~/Library/Mail/V10/` 下的 UUID 形式目錄
2. 讀取每個帳號目錄下的 plist 或直接從 `mailboxes.url` 提取 UUID
3. 使用 AppleScript 一次性查詢所有帳號的 name + id
4. 建立 `[String: String]` (UUID → account name) 快取

此映射在 MCP server 生命週期內通常不變（帳號增刪需重啟 Mail.app），不需要主動刷新。

## Risks / Trade-offs

### [Risk] Envelope Index 路徑可能隨 macOS 版本變更
目前硬編碼 `V10`。Apple 可能在未來 macOS 版本更改路徑。
→ **Mitigation**: 將基礎路徑抽為常數，並加入路徑存在性檢查。若路徑不存在，fallback 到 AppleScript 搜尋（降級模式）。

### [Risk] Full Disk Access 權限
讀取 `~/Library/Mail/` 需要 Full Disk Access 權限。
→ **Mitigation**: 在 MCP server 啟動時檢查路徑可存取性，若無權限則回傳清楚的錯誤訊息說明需要授予 Terminal / Claude Code Full Disk Access。

### [Risk] .emlx 檔案可能被 Mail.app 刪除或移動
Mail.app 在同步、壓縮、清理時可能刪除或移動 `.emlx` 檔案。
→ **Mitigation**: 每次存取 `.emlx` 時檢查檔案存在，不存在時 fallback 到 AppleScript `content of message`。

### [Risk] MIME 解析複雜度
完整的 MIME 解析（multipart、encoded headers、各種 charset）非常複雜。
→ **Mitigation**: 先實作基本的 text/plain + text/html + multipart 解析。對於無法解析的 MIME 結構，fallback 到 AppleScript。使用 Swift 的 `String.Encoding` 處理常見編碼（UTF-8、ISO-8859-1、Big5 等）。

### [Trade-off] SQLite 查詢延遲 vs 資料新鮮度
SQLite 唯讀打開表示我們看到的是 Mail.app 最後一次 checkpoint 的資料。新收到但尚未 checkpoint 的郵件可能不在查詢結果中。
→ **Mitigation**: WAL 模式下 reader 仍能看到 committed transactions，延遲極小（通常 <1 秒）。對於需要最新狀態的操作（如 unread count），可以提供 AppleScript fallback 選項。
