## Why

Apple Mail MCP 目前所有讀取操作（搜尋、列出郵件、取得內容、附件查詢）都透過 AppleScript 與 Mail.app 互動。這導致：

1. **搜尋極慢**：搜尋單一信箱需數秒，跨帳號搜尋更慢（遍歷所有信箱）
2. **無法並行**：Swift actor 序列化 + AppleScript bridge 限制，多個 MCP 呼叫排隊等待
3. **搜尋範圍受限**：只能搜 sender + subject，無法搜收件人/CC 地址
4. **特殊信箱 Bug**：`mailboxRef` 使用 `first mailbox whose name is` 對某些 IMAP 帳號的收件匣無效，導致搜尋回傳空結果

macOS Mail.app 將所有郵件索引儲存在 SQLite 資料庫 `~/Library/Mail/V10/MailData/Envelope Index`，25 萬封郵件的搜尋只需 0.015 秒。郵件內容存為 `.emlx` 檔案（RFC 822 + Apple plist metadata）。直接讀取這些檔案可以完全繞過 AppleScript 的效能瓶頸。

## What Changes

- **新增 SQLite 搜尋引擎**：讀取 `Envelope Index` 資料庫進行郵件搜尋，支援 sender、recipient (to/cc)、subject 的快速查詢
- **新增 .emlx 解析器**：直接讀取 `.emlx` 檔案取得郵件完整內容，無需透過 AppleScript `content of msg`
- **新增批次操作工具**：`get_emails_batch`、`list_attachments_batch` — 在單次 MCP 呼叫中處理多封郵件
- **改進搜尋工具**：`search_emails` 改用 SQLite 後端，支援跨全部帳號搜尋、支援收件人搜尋、支援日期範圍過濾
- **保留 AppleScript 寫入路徑**：寄信、回覆、轉寄、標記、移動等寫入操作繼續使用 AppleScript（SQLite 為唯讀）

## Non-Goals

- **不修改 AppleScript 寫入操作**：compose、reply、forward、move、delete 等操作維持現狀
- **不支援直接寫入 SQLite**：Envelope Index 由 Mail.app 管理，外部寫入會破壞資料一致性
- **不實作 IMAP 直連**：雖然 IMAP SEARCH 功能強大，但需要額外認證、網路依賴，複雜度過高
- **不取代 AppleScript 用於附件下載**：附件儲存路徑由 Mail.app 管理，仍需透過 AppleScript `save attachment`

## Capabilities

### New Capabilities

- `sqlite-query-engine`: 使用 SQLite 直接查詢 Envelope Index 資料庫，提供毫秒級郵件搜尋（sender、recipient、subject、日期範圍）
- `emlx-parser`: 解析 .emlx 檔案格式，提取郵件內容、headers、metadata，無需 AppleScript
- `batch-operations`: 批次讀取多封郵件內容和附件清單的 MCP 工具（`get_emails_batch`、`list_attachments_batch`）

### Modified Capabilities

（無 — 現有 specs 目錄為空，所有能力均為新增）

## Impact

- **受影響的程式碼**:
  - `Sources/CheAppleMailMCP/AppleScript/MailController.swift` — `searchEmails()`、`getEmail()`、`listEmails()` 改用 SQLite 後端
  - `Sources/CheAppleMailMCP/Server.swift` — 新增 `get_emails_batch`、`list_attachments_batch` 工具註冊和路由
  - 新增 `Sources/CheAppleMailMCP/SQLite/EnvelopeIndexReader.swift` — SQLite 查詢層
  - 新增 `Sources/CheAppleMailMCP/SQLite/EmlxParser.swift` — .emlx 檔案解析
- **依賴變更**: 新增 `sqlite3` 系統庫依賴（macOS 內建，無需額外安裝）
- **API 變更**: `search_emails` 回傳格式新增 `account_name`、`mailbox` 欄位（已有的欄位保持向後相容）；新增 `recipient` 搜尋參數
- **權限需求**: 需要 Full Disk Access 權限才能讀取 `~/Library/Mail/`（現有 AppleScript 方式已需要 Mail.app 權限）
