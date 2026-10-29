## Why

#374：列舉結果沒有每封信的草稿狀態，歸檔端只能猜信箱名稱或逐封取 headers。All Mail 的草稿副本使信箱推論不可靠。

## What Changes

- search full／summary、list_emails、get_email_metadata 與 export manifest 增加 nullable `is_draft`。
- 本列或同 global_message_id 的副本為 type 5 或帶草稿 flag（0x40）為 true；type 0 且每一項證據都在、都是否定（含不在名稱為草稿匣或名稱未知的信箱）才是 false；其餘（缺欄位、NULL、其他型別／數值、AppleScript fallback）為 null。驗證後依維護者決定修訂，原本「type 0 為 false」的規則不成立（2026-10-28）。
- **BREAKING（嚴格欄位集合的消費端）**：summary 由五欄增加至六欄，既有欄位與 ids／count 形狀保留。
- 匯出新增 `opts.skip_drafts`，預設 false 維持相容；true 跳過已知草稿，未知狀態則逐筆回報錯誤、不讀 body／attachments。

## Capabilities

### New Capabilities

- `message-draft-status`: 每封訊息的草稿事實與匯出排除選項。

### Modified Capabilities

- `sqlite-query-engine`: search/list/metadata 的欄位與 summary 精確集合更新。

## Impact

MailSQLite reader／SearchResult、Server／fallback serialization、Export manifest／options、工具說明及測試。無 DB 寫入，無實際歸檔遷移；plugins#127 可採用此 API 與匯出選項，但不在此 PR 變更其預設工作流。
