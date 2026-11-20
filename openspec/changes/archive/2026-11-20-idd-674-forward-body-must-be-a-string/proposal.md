## Why

`forward_email` 的 `body` 是選填。handler 用寬鬆的字串讀取，`body` 有給但不是字串時（數字、陣列、物件、boolean）會被當成沒給：沒有 `save_as_draft` 時，不帶附註的轉寄直接送出；有 `save_as_draft` 時被拒絕，但理由寫成「沒有 body」（#674）。

## What Changes

- `forward_email` 的 `body` 有給而且不是字串、也不是 null 時，在任何 Mail 動作之前以參數錯誤拒絕，訊息寫出參數名與實際的型別。兩種模式都一樣。
- 缺少 `body` 或 `body: null` 的意義不變（不帶 body 的轉寄）。字串（包括空字串）的行為不變。

## Non-Goals

- `to` 陣列裡非字串的元素（#733）。
- 其他工具的必填 `body`：它們已經把非字串當成缺少而拒絕。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `message-composition`：ADDED Requirement: forward_email refuses a body that is not a string。

## Impact

- Affected specs: `message-composition`
- Affected code: `Sources/CheAppleMailMCP/Server.swift`
- Tests: `Tests/CheAppleMailMCPTests/ForwardBodyTypeTests.swift`
- Docs: `CHANGELOG.md`
