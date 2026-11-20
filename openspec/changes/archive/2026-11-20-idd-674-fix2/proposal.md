## Why

#674 的 verify 第 2 輪留下七個 in-scope 項目：`body: null` 被當成沒給，規格與測試這樣寫，但 issue 只豁免「缺少」，參數描述與 schema 也沒有講清楚；字串那幾列的測試沒有檢查貼上；工具描述仍寫「恰好兩個原因」會拒絕；情境沒有寫明是寄出模式；requirement 沒有寫必填引數先驗證；拒絕的測試用共享的靜態變數數 script。

## What Changes

- requirement 明寫：明確的 `null` 讀成缺少（與這個 server 其他選填參數相同），所以不帶 `save_as_draft` 時會寄出不帶 body 的轉寄，參數描述要寫明。
- requirement 明寫檢查的位置：在 message id 與必填引數驗證之後、帳號解析之前。
- 情境限定寄出模式；Example 補上缺少與 `null` 搭配 `save_as_draft: true` 的兩列，字串兩列寫出剪貼簿、貼上、寄出的順序。
- 工具描述與 `body` 的參數描述改寫；測試檢查貼上的按鍵在剪貼簿與寄出之間，script 數量跟著每次呼叫回傳。

ASSUMPTION: `null` 讀成缺少是沿用這個 server 既有的慣例（`requireBool`、`optionalStringArray`、`account_id` 都這樣）。issue 的文字只豁免「缺少」。這是在無人值守時取的預設，已在 issue 上記為 Choice Default Record，由維護者決定是否改成拒絕 `null`。

## Non-Goals

- 把 schema 改成可為 null；參數描述建議的寫法是省略這個 key。
- `to` 陣列（#733）、`from_address`（#735）。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `message-composition`：MODIFIED Requirement: forward_email refuses a body that is not a string。

## Impact

- Affected specs: `message-composition`
- Affected code: `Sources/CheAppleMailMCP/Server.swift`（兩段描述）
- Tests: `Tests/CheAppleMailMCPTests/ForwardBodyTypeTests.swift`
- Docs: `mcpb/manifest.json`
