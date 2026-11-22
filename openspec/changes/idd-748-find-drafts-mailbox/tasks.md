## 1. 程式與測試

- [x] 1.1 `MailboxLookup`：封閉的決策表，每一列一條測試（`MailboxLookupTests`）。
- [x] 1.2 `direct-transport.json` 的 `drafts_mailbox`、`sent_mailbox`：可省略、原樣保留、不合格的值以欄位名拒絕。
- [x] 1.3 `SwiftMailSession`：登入後取能力清單；只有宣告 `SPECIAL-USE` 時才呼叫 SwiftMail 的 special-use 查詢。
- [x] 1.4 兩個工具的結果附上信匣來源的 note。

## 2. 文件

- [ ] 2.1 README（兩份）、CHANGELOG、`.claude/rules/direct-transport.md`、兩個工具的說明、`mcpb/manifest.json`。

## 3. 驗證

- [ ] 3.1 全套測試、Codex verify（gpt-6.2-sol、high、ultrafast）、本機 CI 閘門。

## 4. 實際驗證（要維護者同意）

- [ ] 4.1 在 PR 的 head 上建 binary，對 iCloud 跑 `append_draft`（只寄給自己），記下結果的 notes：草稿匣由哪一條找到、伺服器是否宣告 `SPECIAL-USE`。
- [ ] 4.2 接著做 #744 的 4.1、#742 的 5.1／5.2、#745 的 4.1。
