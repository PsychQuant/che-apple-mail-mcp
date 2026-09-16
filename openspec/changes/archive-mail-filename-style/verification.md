## 驗證紀錄

- 2026-09-14：`swift test --filter ArchiveFilenameStyleTests`，10 項、0 失敗。涵蓋 offset 跨日實際 markdown、未知日期、grapheme、跨批碰撞與選項優先權。
- `swift test`：1,265 項、11 項略過、0 失敗。略過沿用既有 opt-in / 環境限制；未操作真實信件歸檔。
- `spectra analyze archive-mail-filename-style --json`：無 Critical / Warning，兩項非必要範例建議；`spectra validate` 通過。
- archive-mail SOP 五項內容檢查通過：schema 能力、style 選項、移除必傳 map、manifest 路徑及不由 UTC preview 算日期。
- Codex 獨立靜態審查 PASS：`/tmp/idd340-review/codex.out`。協調者執行測試，reviewer 未執行測試。審查後僅將日期說明修正為既有 YYYY-MM-DD 前綴判定，未改 runtime 邏輯。
- **尚未完整 verified**：Claude OAuth 過期，四個 Claude lens 與 DA 待登入恢復。保留草稿，不建立 verified tag。

## 已知限制

50 graphemes 可能超過檔案系統的 byte 上限，仍由既有 per-item 寫檔錯誤回報；不私自改成較短名稱。既有 Date parser 接受範圍與日曆驗證不變。本次未安裝 binary、未改使用者既有歸檔檔案。
