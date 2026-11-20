## 1. 測試（RED）

- [x] 1.1 `ForwardBodyTypeTests`（`spec-example: message-composition / forward_email body types`）：帳號不明確時先回報 body、`data:` URL 字串的訊息、空字串照舊走貼上路徑；取 script 改用 `XCTUnwrap`。

## 2. 實作（GREEN）

- [x] 2.1 forward_email refuses a body that is not a string — handler 的檢查順序、`optionalString` 對 data 的說明、`body` 的參數描述、`mcpb/manifest.json`。

## 3. 文件

- [x] 3.1 `CHANGELOG.md`。
