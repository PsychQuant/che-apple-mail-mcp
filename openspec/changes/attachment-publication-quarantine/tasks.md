## 1. 回歸與修正（依序，後項依賴前項）

- [ ] 1.1 Quarantine every published attachment：先新增 AttachmentQuarantineTests，覆蓋 Tier 1、Tier 2、覆寫、空檔、Foundation 屬性解讀；在 macOS CI 記錄修正前失敗。
- [ ] 1.2 描述元隔離標記與失敗不發布：實作 Quarantine every published attachment、Abort publication when quarantine fails；以 AttachmentQuarantineTests 驗證 rename 前 setter、真實 errno 與注入錯誤清理。
- [ ] 1.3 Preserve containment and unrelated writes：symlink 哨兵內容／屬性不變，Markdown 不套用附件政策；執行 AttachmentDestinationTests、AttachmentContainmentIntegrationTests、RaceFreeFileWriterTests 與完整 Swift 測試。

## 2. 證據與交付（依序，使用上列結果）

- [ ] 2.1 獨立驗證與分支、Distinguish verification layers：更新 opt-in Mail 檢查與測試文件，記錄可取得的 macOS／xattr 證據；以 Spectra validate、analyze 與 diff 檢查確認規格一致。
- [ ] 2.2 實際 Mail stage 與發布檔屬性比較、Gatekeeper 啟動檢查；記錄 OS、指令及觀測值，未執行時保留未勾選。
- [ ] 2.3 建立只包含 #573 變更的 draft PR，以 #436 head 為 base；確認兩個 PR 狀態，不合併、不結案。
