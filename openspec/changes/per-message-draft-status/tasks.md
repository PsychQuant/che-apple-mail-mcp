## 1. API

- [x] 1.1 Nullable draft fact：Expose a nullable per-message draft fact，以 SQLite fixture 驗證 0/5、未知、缺欄與 mailbox-independent 判定。
- [x] 1.2 Search result projection and logical dedup：更新 summary/full 序列化與 MIN-row provenance，執行 projection tests。
- [x] 1.3 Get email metadata via SQLite：list/metadata 與 AppleScript fallback 揭露 null，以 schema／fixture 測試驗證。

## 2. 匯出與交付

- [x] 2.1 Explicit export exclusion：Support explicit draft exclusion during export，測試嚴格 boolean 選項及被排除項目無 fetch／write。
- [x] 2.2 Existing archive compatibility：測試預設行為、manifest 欄位與既有 export suite；更新工具描述及 manifest。
- [ ] 2.3 完整 Swift 測試、Spectra validation 與獨立 review，確認證據後更新 PR／issue；完整 ensemble 未完成不得 verified。
