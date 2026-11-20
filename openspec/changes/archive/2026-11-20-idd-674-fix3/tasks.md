## 1. 測試（RED）

- [x] 1.1 `ForwardBodyTypeTests`（`spec-example: message-composition / forward_email body types`）：null 在兩種模式都拒絕且沒有 Mail script；缺少 body 的寄出檢查原生 forward verb 在 `send fwdMsg` 之前；草稿那一列檢查錯誤說明要帶 body。

## 2. 實作（GREEN）

- [x] 2.1 forward_email refuses a body that is not a string — `optionalString` 不再把 null 讀成缺少；工具描述與 `body` 的參數描述；`mcpb/manifest.json`。

## 3. 文件

- [x] 3.1 規格的 requirement、兩個情境與 Example；`CHANGELOG.md`。
