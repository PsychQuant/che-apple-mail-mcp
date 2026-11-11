## 1. 測試先行

- [x] 1.1 Direct-write draft path：帶著 `UUID-A` → `a@example.invalid` 對照建立的伺服器，`directDraftPath()` 的帳號查詢對 `A@EXAMPLE.INVALID` 回 `["UUID-A"]`、對 `nobody@example.invalid` 回空清單，簽名查詢回 nil。驗證：`testTheDirectDraftPathAnswersFromTheInjectedMapping`（spec-example: message-composition / the injected mapping answers and the signature list is unreadable），在修正前編譯失敗或轉紅。
- [x] 1.2 原始碼守門：`Server.swift` 裡唯一的 `DirectDraftPath(` 建構在 `directDraftPath()` 裡，且注入的查詢只用對照。驗證：`IndexReaderWiringGuardTests.testCreateDraftBuildsItsDirectPathThroughTheServersMapping`。

## 2. 實作與文件

- [x] 2.1 `Server.swift` 加 `directDraftPath()`，`create_draft` 改用它；沒有對照時與現在相同。驗證：1.1、1.2 綠；`DirectDraftPathTests`（閉包預設值）與 `DirectWriteSafetyGuardTests` 仍綠。
- [x] 2.2 `CHANGELOG.md`：#633 條目裡「直接寫入路徑仍讀 plist」那句改成已由 #654 處理，並加 #654 條目。驗證：內容審閱。
- [ ] 2.3 全部測試：兩個 bundle 都 0 failures。驗證：分別讀兩個 bundle 的 `Executed N tests` 行。
