## 1. 測試（RED）

- [x] 1.1 組信：標頭集合與各一次、CRLF、`7bit`／`base64`、RFC 2047、摺行不拆位址、不是 Mail 草稿版面（Requirement: append_draft creates one new draft on the server and builds it itself）。
- [x] 1.2 內容檢查：收件人至少一個、純位址、主旨不空、控制字元、NUL；都在開連線之前（同上）。
- [x] 1.3 三種結果與 `unknown` 之後的一次搜尋（`spec-example: direct-transport / append outcomes`）。
- [x] 1.4 SwiftMail 錯誤分類：`commandFailed`、`appendLimitExceeded` 以外都是 `unknown`（Requirement: An append has one of three outcomes and is never repeated）。
- [x] 1.5 工具：封閉參數、型別、設定與憑證、結果的 JSON、說明的但書（Requirement: append_draft states that it has not been run against a real server）。
- [x] 1.6 `send_draft` 的 `message_id`：選中、不讀本機、找不到、只有子字串相符的命中、與其他選擇器並用、格式錯誤（Requirement: send_draft sends one existing draft and cannot write content）。
- [x] 1.7 APPEND 之前的失敗回 `not_appended`、目的信匣是伺服器標的草稿匣、共用鎖、建草稿後以 `message_id` 寄出的整段流程（verify 第 1 輪）。

## 2. 實作（GREEN）

- [x] 2.1 `DraftMessage`（組信）。
- [x] 2.2 `DirectTransportSession.appendDraft` 與 `SwiftMailSession` 的實作、`classifyAppend`。
- [x] 2.3 `AppendDraftFlow`、`AppendDraftTool`；`Server.swift` 註冊與分派；`ToolAccess` 列為 `prepareMail`。
- [x] 2.4 `send_draft` 的 `message_id` 選擇器。

## 3. 文件

- [x] 3.1 `README.md`、`README_zh-TW.md`、`CHANGELOG.md`、`mcpb/manifest.json`、`server.json`。
- [x] 3.2 `.claude/rules/direct-transport.md` 涵蓋 `append_draft`。

## 4. 實際驗證（要維護者同意；issue 在這之前保持開啟並貼 `blocked-on-setup`）

- [x] 1.8 遮蔽在結果邊界（三條錯誤路徑）、鎖持有到關閉連線、每次呼叫不同的 Message-ID、最長可接受的標頭、大小上限、`message_id` 取信後的身分檢查（verify 第 2 輪）。
- [x] 1.9 結果裡伺服器給的信匣名稱也遮蔽、全是換行的內文一次掃完、每個 encoded word 各自是合法 UTF-8 且不超過 75 字元、原始清單的收件人數、`message_id` 長度上限（verify 第 3 輪）。
- [ ] 4.1 草稿 A，Mail 全程關著：`append_draft`（只寄給自己），記下結果、伺服器回覆、是否回報 UID；在任何用戶端打開之前，以 IMAP 讀回它的旗標，確認有 `\Draft` 與 `\Seen`；接著用回傳的 `message_id` 以 `send_draft` 寄出，讀收到那封信的原始內容。
- [ ] 4.2 草稿 B：`append_draft` 之後在 Mail 與另一個用戶端打開，看是否列為可編輯的草稿；Mail 同步後本機索引是否出現它。用完刪掉。
