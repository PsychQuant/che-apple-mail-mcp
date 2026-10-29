## 1. API

- [x] 1.1 Nullable draft fact：Expose a nullable per-message draft fact，以 SQLite fixture 驗證 0/5、未知、缺欄與 mailbox-independent 判定。
- [x] 1.2 Search result projection and logical dedup：更新 summary/full 序列化與 MIN-row provenance，執行 projection tests。
- [x] 1.3 Get email metadata via SQLite：list/metadata 與 AppleScript fallback 揭露 null，以 schema／fixture 測試驗證。

## 2. 匯出與交付

- [x] 2.1 Explicit export exclusion：Support explicit draft exclusion during export，測試嚴格 boolean 選項及被排除項目無 fetch／write。
- [x] 2.2 Existing archive compatibility：測試預設行為、manifest 欄位與既有 export suite；更新工具描述及 manifest。
- [ ] 2.3 完整 Swift 測試、Spectra validation 與獨立 review，確認證據後更新 PR／issue；完整 ensemble 未完成不得 verified。

## 3. Verify 修正（2026-10-28）

- [x] 3.1 草稿判定：type 5、草稿 flag、或副本的這兩項證據 → true；type 0 且無證據、本列與副本都不在草稿匣名稱的信箱 → false；其餘 null（維護者決定）。以合成 fixture 測試各情況。
- [x] 3.2 匯出：draft_skipped 狀態與 drafts_skipped 計數；查詢失敗附原因；放錯位置的 skip_drafts 與非物件 opts 被拒。
- [x] 3.3 schema 無法檢查時狀態為 unknown、reader 照常開啟；README、CHANGELOG、工具說明。

