## 1. 邊界實作

- [x] 1.1 共用目的地能力：Authorize the full destination before side effects；以 AttachmentDestinationTests 驗證原始元件、完整 allowed roots 與型別化拒絕。
- [x] 1.2 私有暫存與串流發布：Publish through a pinned directory；以 AttachmentDestinationTests 驗證唯一 temp、bounded copy、stage 驗證及清理。
- [x] 1.3 失敗分流：SQLite／empty／MailController overload／retry 整合，Isolate all attachment backends；以附件 runner seam 測試確認發布失敗不可 fallback。

## 2. 驗證與交付

- [x] 2.1 加入惡意與正常控制組，更新既有附件測試並執行 focused 與完整 Swift 測試。
- [x] 2.2 更新工具描述及設定文件，執行一次獨立 candidate bypass review 並處理確認的問題。
- [x] 2.3 實際 Mail staging 整合驗證：唯一合成本機信箱、真 Mail save → production stage／publish，45 bytes 一致；成功與寫後中斷皆清理 stage，原輸出保留。專用信箱以 UI 移除並原生查無；見 docs/testing/attachment-staging.md。
- [ ] 2.4 完整 IDD ensemble、PR 與 issue 狀態更新。
