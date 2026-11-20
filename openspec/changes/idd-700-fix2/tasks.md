## 1. 測試（RED）

- [x] 1.1 最後一道 guard 只讀一次 front window 的 id，檢查與輪詢用同一個值（`spec-example: message-composition / send confirmation by window close`）。
- [x] 1.2 錯誤文字是「at least N seconds」（`spec-example: message-composition / send confirmation wait`）。
- [x] 1.3 check 本身出的錯沿用既有的 post-dispatch 訊息（`spec-example: message-composition / unconfirmed send message`）。

## 2. 實作（GREEN）

- [x] 2.1 A reply or forward is reported as sent only after its compose window has closed — `buildReplyForwardPasteScript` 的最後一道 guard 與錯誤文字。

## 3. 文件

- [x] 3.1 CHANGELOG、README 工具表兩列。
