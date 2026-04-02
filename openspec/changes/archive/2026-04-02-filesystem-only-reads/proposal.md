## Summary

將所有讀取/查詢操作從 AppleScript 改為純 filesystem 存取（SQLite Envelope Index + .emlx + plist），徹底消除 AppleScript 在讀取路徑的依賴。

## Motivation

v2.0.0 新增了 SQLite 搜尋引擎和 .emlx 解析器，但 `ensureAccountMapping()` 仍然使用 AppleScript 查詢帳號名稱。在 MCP stdio 環境下，AppleScript 呼叫會 hang（Mail.app 可能不在前景、授權提示無法顯示），導致 `search_emails` 和 `get_email` 完全無法使用。

此外，`list_accounts`、`get_account_info`、`list_mailboxes`、`list_emails`、`get_unread_count`、`list_attachments`、`get_email_headers`、`get_email_source`、`get_email_metadata` 等讀取操作仍然完全透過 AppleScript，在大量郵件的環境下效能差、且受制於 actor 序列化。

核心目標：**讀取路徑零 AppleScript 依賴** — MCP server 啟動和所有查詢操作不觸發任何 AppleScript 呼叫，實現毫秒級回應。

## Proposed Solution

利用已驗證的三個 filesystem 資料來源完全取代 AppleScript 讀取：

1. **SQLite Envelope Index** (`~/Library/Mail/V10/MailData/Envelope Index`)
   - `messages` + `subjects` + `addresses` + `mailboxes` + `recipients` + `attachments` 表覆蓋全部郵件元資料查詢
   - `mailboxes.unread_count` / `mailboxes.total_count` 提供信箱統計

2. **AccountsMap.plist** (`~/Library/Mail/V10/MailData/Signatures/AccountsMap.plist`)
   - UUID → AccountURL 對應，AccountURL 包含帳號 email（可作為帳號名稱）
   - 讀取一次即可建立完整帳號映射，無需 AppleScript

3. **.emlx 檔案** — 已實作，提供郵件全文、headers、source

### 需要改為 filesystem 的操作（11 個）

| 工具 | 現行方式 | 改為 |
|------|---------|------|
| `list_accounts` | AppleScript | AccountsMap.plist + UUID 目錄掃描 |
| `get_account_info` | AppleScript | AccountsMap.plist + SQLite 統計 |
| `list_mailboxes` | AppleScript | SQLite `mailboxes` 表 |
| `list_emails` | AppleScript | SQLite 查詢 |
| `get_unread_count` | AppleScript | SQLite `mailboxes.unread_count` |
| `list_attachments` | AppleScript | SQLite `attachments` 表 |
| `get_email_headers` | AppleScript | .emlx parser |
| `get_email_source` | AppleScript | .emlx parser |
| `get_email_metadata` | AppleScript | SQLite 欄位 |
| `ensureAccountMapping` | AppleScript | AccountsMap.plist |
| `list_vip_senders` | AppleScript | `VIPMailboxes.plist` |

### 維持 AppleScript 的操作（寫入類）

compose_email、reply_email、forward_email、redirect_email、mark_read、flag_email、set_flag_color、set_background_color、mark_as_junk、move_email、copy_email、delete_email、create_mailbox、delete_mailbox、save_attachment、create_draft、list_drafts、create_rule、delete_rule、enable_rule、get_rule_details、list_rules、check_for_new_mail、synchronize_account、open_mailto、import_mailbox、extract_name_from_address、extract_address、get_mail_app_info、list_smtp_servers、list_signatures、get_signature

## Non-Goals

- 不改動任何寫入操作的 AppleScript 實作
- 不取代 `save_attachment`（附件儲存路徑由 Mail.app 管理）
- 不實作 Mail rule 的 filesystem 讀取（規則格式複雜且較少使用）
- 不改變 MCP tool 的外部 API 介面（參數和回傳格式保持向後相容）

## Impact

- **受影響的 specs**: sqlite-query-engine（修改：新增 list_emails、list_mailboxes、get_unread_count、list_attachments 查詢）、emlx-parser（修改：新增 get_email_headers、get_email_source 支援）
- **受影響的程式碼**:
  - `Sources/MailSQLite/EnvelopeIndexReader.swift` — 新增 listEmails、listMailboxes、getUnreadCount、listAttachments 方法
  - `Sources/MailSQLite/AccountMapper.swift` — 新增，從 AccountsMap.plist 讀取帳號映射
  - `Sources/MailSQLite/EmlxParser.swift` — 新增 readHeaders、readSource 方法
  - `Sources/CheAppleMailMCP/Server.swift` — 11 個 case 改用 filesystem 路徑，移除 ensureAccountMapping
