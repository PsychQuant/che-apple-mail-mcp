## 1. 測試先行（RED）

- [x] 1.1 新增 `Tests/CheAppleMailMCPTests/SendConfirmedByWindowCloseTests.swift`，帶標記 `spec-example: message-composition / send confirmation by window close`：寄出的 reply 與 forward script 在 dispatch 之後、成功標籤之前輪詢 `id of every window`，到期丟 `SENDUNCONFIRMED`，不含關視窗的動作；草稿 script 不含輪詢；`CHE_MAIL_SEND_CONFIRM_WAIT` 的預設與範圍；script 可以通過 `osacompile`。驗證：實作前失敗。
- [x] 1.2 同一個檔案，帶標記 `spec-example: message-composition / unconfirmed send message`：`unknownReplyForwardSendStateError` 對三種輸入的訊息與回傳錯誤的分類；經 `replyEmail`／`forwardEmail` 的 seam 走一次。驗證：實作前失敗。
- [x] 1.3 描述守門：`reply_email` 與 `forward_email` 的描述說明成功的意思、不是伺服器確認、live 但書（#700）。驗證：實作前失敗。

## 2. 實作（GREEN）

- [x] 2.1 A reply or forward is reported as sent only after its compose window has closed — `buildReplyForwardPasteScript` 的寄出後確認；`unknownReplyForwardSendStateError` 的新分支；`Server.swift` 兩個描述。驗證：1.1–1.3 轉綠，全套測試綠。

## 3. 文件

- [x] 3.1 `mcpb/manifest.json` 重新產生；README（工具表與 After a timeout）；`CHANGELOG.md` Unreleased；`.claude/rules/timeout-outcome-boundary.md` 補上寄出後確認與它的界線。驗證：`make test` 綠。
