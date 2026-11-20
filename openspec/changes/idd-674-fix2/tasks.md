## 1. 測試（RED）

- [x] 1.1 `ForwardBodyTypeTests`（`spec-example: message-composition / forward_email body types`）：字串兩列檢查剪貼簿、貼上、寄出的順序；缺少與 `null` 在寄出與草稿兩種模式的結果；每次呼叫回傳自己的 script 清單與錯誤。

## 2. 實作（GREEN）

- [x] 2.1 forward_email refuses a body that is not a string — 工具描述與 `body` 的參數描述；`mcpb/manifest.json`。

## 3. 文件

- [x] 3.1 規格的 requirement、情境與 Example。
