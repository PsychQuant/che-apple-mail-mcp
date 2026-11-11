## 1. 測試先行

- [x] 1.1 Direct-write draft path：`messages` 讀不到時，讀已讀旗標回「讀不到」（nil），stderr 有 `messages.read read failed`。驗證：`testAFailedReadFlagReadNamesItsCause`（spec-example: message-composition / a missing messages table is reported on stderr），在修正前失敗。
- [x] 1.2 Direct-write draft path：資料列不存在時回 nil、stderr 沒有輸出。驗證：`testAReadFlagRowThatIsGoneLogsNothing`（spec-example: message-composition / a deleted draft row reads as cannot tell without a log line）；讓「找不到列」也寫 log 的 mutation 必須讓它轉紅。

## 2. 實作與文件

- [x] 2.1 `DraftStoreWriter.readFlag` 改成 do/catch，失敗經 `logReadFailure("messages.read", error)` 寫 stderr 並回 nil；簽名不變，`ensureRead`／`attemptSteps` 不動。驗證：1.1、1.2 綠，`DirectWriteSafetyGuardTests` 與 `DirectDraftPathOutcomeTests` 其他測試仍綠。
- [x] 2.2 `.claude/rules/direct-write-transaction-safety.md` 的 `readFlag` 覆蓋句補上讀取失敗的測試；`CHANGELOG.md` 加條目。驗證：內容審閱。
- [ ] 2.3 全部測試：兩個 bundle 都 0 failures。驗證：分別讀兩個 bundle 的 `Executed N tests` 行。
