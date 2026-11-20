## Why

#674 的 verify 第 3 輪，六席 reviewer 都指出同一點：明確的 `body: null` 仍被讀成沒給 body 而寄出不帶附註的轉寄，issue 只豁免「缺少 body」。維護者在 issue 上決定拒絕 null（2026-11-20 的 Decision）。同一輪另有四項：不帶 body 的測試沒有檢查原生 forward verb 與草稿錯誤的說明；工具描述說任何非字串都拒絕、卻又接受 null；把 paste 路徑的兩個檢查寫成全部的拒絕原因；requirement 說必填引數「已驗證」，實際只檢查存在與外層型別。

## What Changes

- `body: null` 拒絕：`'body' must be a string, got: null`，有無 `save_as_draft` 都一樣，沒有 Mail 動作。只有缺少這個 key 才是不帶 body 的轉寄。
- requirement 寫明這與其他選填參數對 null 的讀法不同，以及原因；檢查排在必填引數的存在與外層型別檢查之後。
- 情境拆成兩個：缺少 body、明確的 null。Example 的 null 兩列改成拒絕；缺少的兩列寫出原生 forward verb 與草稿錯誤的說明。
- 工具描述與參數描述跟著改；測試補上 null 兩列、forward verb 的順序、草稿錯誤的文字。

## Non-Goals

- 其他選填參數對 null 的讀法（`save_as_draft`、`cc_additional`、`account_id`）不變。
- `to` 陣列的元素（#733）、`from_address`（#735）。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `message-composition`：MODIFIED Requirement: forward_email refuses a body that is not a string。

## Impact

- Affected specs: `message-composition`
- Affected code: `Sources/CheAppleMailMCP/Server.swift`（`optionalString`、兩段描述）
- Tests: `Tests/CheAppleMailMCPTests/ForwardBodyTypeTests.swift`
- Docs: `CHANGELOG.md`、`mcpb/manifest.json`
- 行為改變：原本傳 `body: null` 的呼叫端會從「寄出不帶附註的轉寄」變成拿到錯誤。
