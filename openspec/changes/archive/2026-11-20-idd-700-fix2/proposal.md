## Why

#700 的 verify 第 2 輪留下五個 in-scope 項目：最後一道 guard 讀了兩次 front window 的 id，檢查的與之後輪詢的可能不是同一個視窗；未確認的錯誤寫了確切的秒數，但那只是下限；requirement 沒有寫這段等待取代了寄信按鍵後的固定停頓；「check 本身出錯」沒有 Example 與測試；README 工具表兩列少了句號。

## What Changes

- 最後一道 guard 只讀一次 front window 的 id：存起來、檢查它屬於這次呼叫開的視窗、之後輪詢同一個值。
- 未確認的錯誤改寫成「at least N seconds」。
- requirement 補上：等待取代了固定停頓，`CHE_MAIL_MAILTO_STEP_DELAY` 不適用；錯誤裡的秒數是下限。
- Example `unconfirmed send message` 加一列：check 本身出的錯沿用既有的 post-dispatch 訊息；補上測試。
- CHANGELOG 與 README 的文字修正。

## Non-Goals

- 剪貼簿在等待期間的還原時機（#732）。
- live 驗證（#700 保持開啟）。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `message-composition`：MODIFIED Requirement: A reply or forward is reported as sent only after its compose window has closed。

## Impact

- Affected specs: `message-composition`
- Affected code: `Sources/CheAppleMailMCP/AppleScript/ComposeScriptBuilder.swift`
- Tests: `Tests/CheAppleMailMCPTests/SendConfirmedByWindowCloseTests.swift`
- Docs: `README.md`、`CHANGELOG.md`
