## 1. 測試（RED）

- [x] 1.1 `SendConfirmedByWindowCloseTests`：script 在 dispatch 前於確認 front window 的同一個 `tell` 記下 `_sentWindowId`，輪詢只看它（`spec-example: message-composition / send confirmation by window close`，草稿列補上結果標籤）。
- [x] 1.2 等待時間的八列（`spec-example: message-composition / send confirmation wait`）。
- [x] 1.3 未確認訊息不含寄信的指示；另外兩列的輸入與措辭逐字比對（`spec-example: message-composition / unconfirmed send message`）。
- [x] 1.4 描述：`forward_email` 限定帶 body 並說明不帶 body 沒有確認；live 但書另立為暫時的測試。

## 2. 實作（GREEN）

- [x] 2.1 A reply or forward is reported as sent only after its compose window has closed — `buildReplyForwardPasteScript` 只看寄信按鍵落下的視窗；`unknownReplyForwardSendStateError` 的措辭；`Server.swift` 兩個描述；`mcpb/manifest.json`。

## 3. 文件

- [x] 3.1 CHANGELOG、README（工具表兩列與 After a timeout）、`.claude/rules/timeout-outcome-boundary.md`。
