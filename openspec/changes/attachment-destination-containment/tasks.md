## 1. 邊界實作

- [x] 1.1 共用目的地能力：Authorize the full destination before side effects；以 AttachmentDestinationTests 驗證原始元件、完整 allowed roots 與型別化拒絕。
- [x] 1.2 私有暫存與串流發布：Publish through a pinned directory；以 AttachmentDestinationTests 驗證唯一 temp、bounded copy、stage 驗證及清理。
- [x] 1.3 失敗分流：SQLite／empty／MailController overload／retry 整合，Isolate all attachment backends；以附件 runner seam 測試確認發布失敗不可 fallback。

## 2. 驗證與交付

- [x] 2.1 加入惡意與正常控制組，更新既有附件測試並執行 focused 與完整 Swift 測試。
- [x] 2.2 更新工具描述及設定文件，執行一次獨立 candidate bypass review 並處理確認的問題。
- [x] 2.3 實際 Mail staging 整合驗證：唯一合成本機信箱、真 Mail save → production stage／publish，45 bytes 一致；成功與寫後中斷皆清理 stage，原輸出保留。專用信箱以 UI 移除並原生查無；見 docs/testing/attachment-staging.md。
- [ ] 2.4 完整 IDD ensemble、PR 與 issue 狀態更新。

## 3. Verify 修正（2026-10-28）

- [x] 3.1 雲端同步資料夾（維護者決定）：`CloudStorage` 底下已存在的 provider 資料夾、iCloud Drive、各 app iCloud 容器的 `Documents` 預設允許，其餘 `~/Library` 照樣拒絕；export 共用同一政策。被拒名稱的連結與被拒資料夾第一層的連結，目標一併拒絕。
- [x] 3.2 denylist 名稱改用 full case folding 比對，並加入 shell 啟動檔與 agent 設定。
- [x] 3.3 root 為 `/`、無法解析的 root、檔案權限（暫存檔私有、新檔依 umask、覆寫保留讀寫位元、不保留執行位元）、Tier 1 讀到 0 bytes 改走 Tier 2、暫存區錯誤為 stage_failed。
- [x] 3.4 SOP 分開回報目的地被拒；README、CHANGELOG、emlx-parser 的 MODIFIED delta。

