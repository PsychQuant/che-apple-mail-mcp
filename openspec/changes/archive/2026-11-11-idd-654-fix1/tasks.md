## 1. 測試

- [x] 1.1 `IndexReaderWiringGuardTests.testCreateDraftBuildsItsDirectPathThroughTheServersMapping` 比對 `directDraftPath()` 去掉註解後的整段程式，順序固定。驗證：把簽名覆寫移到 `guard` 之前的 mutation 讓它轉紅。
- [x] 1.2 Direct-write draft path：iCloud 簽名存在時閘門 (3) 讀不到清單。驗證：`DirectDraftPathTests.testICloudSignaturesMakeTheLocalListUnknown`（spec-example: message-composition / an empty local list becomes unreadable once iCloud signatures appear）。

## 2. 文件

- [x] 2.1 `CHANGELOG.md` 的 #654 條目與 `Server.swift` 工廠註解改寫閘門 (3) 的說法。驗證：內容審閱。
- [x] 2.2 全部測試：兩個 bundle 都 0 failures。驗證：分別讀兩個 bundle 的 `Executed N tests` 行。
