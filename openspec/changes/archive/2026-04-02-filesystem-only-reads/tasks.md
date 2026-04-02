## 1. AccountMapper — 帳號映射（取代 AppleScript ensureAccountMapping）

- [x] 1.1 建立 `Sources/MailSQLite/AccountMapper.swift`，實作 Account UUID to name mapping：讀取 `~/Library/Mail/V10/MailData/Signatures/AccountsMap.plist`，解析 UUID → AccountURL，從 AccountURL 提取 percent-decoded email 作為帳號名稱，回傳 `[String: String]` 映射
- [x] 1.2 修改 `EnvelopeIndexReader.init()`：改用 `AccountMapper.buildMapping()` 取代空映射。在 init 時同步讀取 plist（無 AppleScript、無 async、不會 hang）
- [x] 1.3 移除 `Server.swift` 中的 `ensureAccountMapping()` 方法和所有 `await ensureAccountMapping()` 呼叫，以及 `accountMappingBuilt` 屬性

## 2. SQLite 讀取方法擴充

- [x] [P] 2.1 在 `EnvelopeIndexReader` 新增 `listAccounts()` 方法：實作 List accounts via filesystem — 掃描 UUID 目錄 + AccountMapper 映射，回傳帳號列表
- [x] [P] 2.2 在 `EnvelopeIndexReader` 新增 `listMailboxes(accountName:)` 方法：查詢 SQLite `mailboxes` 表，解碼 URL，回傳 mailbox 名稱、total_count、unread_count（List mailboxes via SQLite）
- [x] [P] 2.3 在 `EnvelopeIndexReader` 新增 `listEmails(mailbox:accountName:limit:)` 方法：JOIN messages+subjects+addresses+mailboxes，回傳 id、subject、sender、date_received（List emails via SQLite）
- [x] [P] 2.4 在 `EnvelopeIndexReader` 新增 `getUnreadCount(mailbox:accountName:)` 方法：讀取 `mailboxes.unread_count`，支援按信箱/帳號過濾和全域加總（Get unread count via SQLite）
- [x] [P] 2.5 在 `EnvelopeIndexReader` 新增 `listAttachments(messageId:)` 方法：查詢 `attachments` 表 WHERE message = ROWID，回傳 name 和 attachment_id（List attachments via SQLite）
- [x] [P] 2.6 在 `EnvelopeIndexReader` 新增 `getEmailMetadata(messageId:)` 方法：查詢 `messages` 表取 read、flagged、deleted、size、date_received（Get email metadata via SQLite）
- [x] 2.7 在 `EnvelopeIndexReader` 新增 `listVIPSenders()` 方法：讀取 `~/Library/Mail/V10/MailData/VIPMailboxes.plist`，回傳 VIP email 地址列表（List VIP senders via filesystem）

## 3. .emlx 讀取方法擴充

- [x] [P] 3.1 在 `EmlxParser` 新增 `readHeaders(rowId:mailboxURL:)` 方法：讀取 .emlx 檔案，回傳 headers 原始文字（空行之前的部分）（Get email headers via emlx）
- [x] [P] 3.2 在 `EmlxParser` 新增 `readSource(rowId:mailboxURL:)` 方法：讀取 .emlx 檔案，回傳完整 RFC 822 訊息資料字串（Get email source via emlx）

## 4. Server.swift 路由切換

- [x] 4.1 `list_accounts` 改用 `indexReader.listAccounts()`，fallback AppleScript
- [x] 4.2 `get_account_info` 改用 `indexReader.listAccounts()` 取帳號資訊 + SQLite 統計，fallback AppleScript
- [x] [P] 4.3 `list_mailboxes` 改用 `indexReader.listMailboxes()`，fallback AppleScript
- [x] [P] 4.4 `list_emails` 改用 `indexReader.listEmails()`，fallback AppleScript
- [x] [P] 4.5 `get_unread_count` 改用 `indexReader.getUnreadCount()`，fallback AppleScript
- [x] [P] 4.6 `list_attachments` 改用 `indexReader.listAttachments()`，fallback AppleScript
- [x] [P] 4.7 `get_email_headers` 改用 `EmlxParser.readHeaders()`，fallback AppleScript
- [x] [P] 4.8 `get_email_source` 改用 `EmlxParser.readSource()`，fallback AppleScript
- [x] [P] 4.9 `get_email_metadata` 改用 `indexReader.getEmailMetadata()`，fallback AppleScript
- [x] 4.10 `list_vip_senders` 改用 `indexReader.listVIPSenders()`，fallback AppleScript

## 5. 測試與驗證

- [x] [P] 5.1 AccountMapper 單元測試：plist 解析、percent decoding、plist 不存在時 fallback
- [x] [P] 5.2 新增 SQLite 查詢方法的整合測試：listMailboxes、listEmails、getUnreadCount、listAttachments、getEmailMetadata 針對真實 Envelope Index
- [x] [P] 5.3 readHeaders / readSource 單元測試
- [x] 5.4 MCP server 啟動測試：確認 initialize 回應在 1 秒內完成（無 AppleScript 阻塞）
- [x] 5.5 Fallback 路徑測試：indexReader 為 nil 時全部 11 個操作 fallback 到 AppleScript
