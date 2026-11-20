## Why

`reply_email` 回報 `Reply sent successfully (paste path)`，信卻留在開著的 compose 視窗裡（#700）。寄出的 script 在送出 ⇧⌘D 之後只等一段固定時間就回傳成功，沒有再看一次自己開的視窗；鍵盤事件送出去了被回報成信寄出了。帶 body 的 `forward_email` 走同一個函式，有同樣的缺口。

## What Changes

- `reply_email` 與帶 body 的 `forward_email` 的寄出流程：送出寄信按鍵後，在 Mail 的 context 輪詢這次呼叫開出來的視窗（依視窗 id）。視窗都不在了才回報成功；等待期限（預設 10 秒，`CHE_MAIL_SEND_CONFIRM_WAIT`，0–10）到了還在，就以寄送狀態未知回報，不重試，不關那個視窗。
- 未確認時的訊息說明觀察到的事（compose 視窗仍開著）、寄送狀態是 UNKNOWN、不重試，並指向那個視窗；既有的逾時與 post-dispatch 訊息逐字不變，三個站點的判斷式不動。
- 成功訊息的文字不變；工具描述與 README 說明它的意思是「按鍵已送出且 compose 視窗已關閉」，不代表伺服器已收下，以及這個確認尚未在真的寄出上跑過（#700 保持開啟直到 live 驗證）。
- 草稿流程（`save_as_draft: true`）不變。

## Non-Goals

- `compose_email` 的 mailto 寄出路徑（#730）。
- 查出 #700 那一次為什麼寄信按鍵沒有生效。
- 讀寄件備份或寄件匣來確認伺服器已收下（`timeout-outcome-boundary.md` 的 S1–S3 尚未量測）。

ASSUMPTION: 寄出成功後，Mail 會讓該 compose 視窗的 id 離開 `id of every window`。草稿路徑 `close … saving yes` 之後 id 消失已有 live 紀錄；寄出路徑沒有。若這個假設不成立，成功的寄出會被回報成未確認（不會重寄）。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `message-composition`：ADDED Requirement: A reply or forward is reported as sent only after its compose window has closed。

## Impact

- Affected specs: `message-composition`
- Affected code: `Sources/CheAppleMailMCP/AppleScript/ComposeScriptBuilder.swift`（`buildReplyForwardPasteScript`）、`Sources/CheAppleMailMCP/TimeoutOutcomeHint.swift`（`unknownReplyForwardSendStateError`）、`Sources/CheAppleMailMCP/Server.swift`（兩個工具描述）
- Tests: `Tests/CheAppleMailMCPTests/SendConfirmedByWindowCloseTests.swift`
- Docs: `README.md`、`CHANGELOG.md`、`mcpb/manifest.json`、`.claude/rules/timeout-outcome-boundary.md`
