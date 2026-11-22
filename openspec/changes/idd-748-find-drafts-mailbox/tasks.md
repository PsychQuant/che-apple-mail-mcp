## 1. 程式與測試

- [x] 1.1 `MailboxLookup`：封閉的決策表，每一列一條測試（`MailboxLookupTests`）。
- [x] 1.2 `direct-transport.json` 的 `drafts_mailbox`、`sent_mailbox`：可省略、原樣保留、不合格的值以欄位名拒絕。
- [x] 1.3 `SwiftMailSession`：登入後取能力清單；只有宣告 `SPECIAL-USE` 時才呼叫 SwiftMail 的 special-use 查詢。
- [x] 1.4 兩個工具的結果附上信匣來源的 note（protocol requirement，經 protocol 呼叫也拿得到）。
- [x] 1.5 寄件備份匣與草稿匣是同一個信匣時（不分 ASCII 大小寫），寄件副本留 pending、草稿不移除。
- [x] 1.6 伺服器標的信匣若是 `\Noselect` 就拒絕，不改用設定的名稱；能力清單讀不到就拒絕（第 2 輪 verify）。
- [x] 1.7 已寄出紀錄記下送出時的草稿匣；只剩收尾時，草稿匣不是那一個就拒絕，也不把「找不到草稿」當成已移除；同信匣的檢查改成不分 ASCII 大小寫；特殊用途查詢失敗也拒絕；拒絕訊息不帶伺服器或程式庫的錯誤文字（第 3 輪 verify）。

## 2. 文件

- [ ] 2.1 README（兩份）、CHANGELOG、`.claude/rules/direct-transport.md`、兩個工具的說明、`mcpb/manifest.json`。

## 3. 驗證

- [ ] 3.1 全套測試、跨模型驗證、本機 CI 閘門。

## 4. 實際驗證（要維護者同意）

- [ ] 4.1 在 PR 的 head 上建 binary，對 iCloud 跑 `append_draft`（只寄給自己），記下結果的 notes：草稿匣由哪一條找到；用到第 3 條以後時，伺服器登入後是否宣告 `SPECIAL-USE`。
- [ ] 4.2 接著做 #744 的 4.1、#742 的 5.1／5.2（`sent_copy: append`，記下寄件備份匣由哪一條找到）、#745 的 4.1。

結果的 notes 只說明走了決策表的哪一條，不證明 SwiftMail 在線上送了什麼指令；那要另外的 IMAP 對話紀錄測試，見 #749。
