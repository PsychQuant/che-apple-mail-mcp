## 1. 測試先行（RED）

- [x] 1.1 新增 `Tests/CheAppleMailMCPTests/ForwardSaveAsDraftTests.swift`，帶標記 `spec-example: message-composition / forward_email save_as_draft`：逐列檢查 Example（builder 的按鍵與標籤、不帶內文時拒絕且不跑任何 script、非 boolean 拒絕、預設行為不變）。驗證：實作前失敗。
- [x] 1.2 草稿路徑的逾時不是 unknown-send-state，寄出路徑仍是；`GuiScriptTimeoutTests` 的計數不變。驗證：實作前失敗或維持綠。
- [x] 1.3 描述守門：`forward_email` 描述第一句寫明會寄出、提到 `save_as_draft`、#461 讀回、live 但書；`ReplyForwardDisclosureGuardTests` 維持綠。驗證：實作前失敗。

## 2. 實作（GREEN）

- [x] 2.1 forward_email can save the forward as a draft — `buildForwardEmailPasteScript(saveAsDraft:)`、`MailController.forwardEmail(saveAsDraft:)`（同一個 dispatch；草稿流程不查兩道判斷，錯誤原樣傳出，寄出流程的判斷一字不改）、`Server.swift` schema／描述／handler（`requireBool`）。驗證：1.1–1.3 轉綠，全套測試綠。

## 3. 文件

- [x] 3.1 `compose-wrapper-free.md`（repo 規則與 plugin 副本）第十列；`confirmation-triggers.md`、`confirmation-protocol` skill；README 工具表；`CHANGELOG.md` 與 `plugin/CHANGELOG.md` 的 Unreleased。驗證：內容審閱；`swift test` 與 plugin 測試綠。
