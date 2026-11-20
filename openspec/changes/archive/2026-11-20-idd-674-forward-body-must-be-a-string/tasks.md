## 1. 測試先行（RED）

- [x] 1.1 新增 `Tests/CheAppleMailMCPTests/ForwardBodyTypeTests.swift`，帶標記 `spec-example: message-composition / forward_email body types`：逐列檢查 Example。驗證：實作前失敗。

## 2. 實作（GREEN）

- [x] 2.1 forward_email refuses a body that is not a string — `optionalString` helper；`forward_email` handler 改用它。驗證：1.1 轉綠，全套測試綠。

## 3. 文件

- [x] 3.1 `CHANGELOG.md` Unreleased。
