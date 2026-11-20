## Why

#674 的 verify 第 1 輪留下五個 in-scope 項目：`body` 的型別檢查排在帳號解析之後，帳號解析失敗時呼叫端看不到 body 的錯誤；測試在不會中止的 count 斷言之後直接取 `scripts[0]`；requirement 寫了空字串照舊，卻沒有 Example 列與測試；`body` 的參數描述沒有提到非字串會被拒絕；被 MCP SDK 解成二進位資料的 `data:` URL 字串會得到 `got: data`，訊息沒有說明原因，Example 的「ending in send」也比測試檢查的寬。

## What Changes

- `body` 的型別檢查移到帳號解析之前。
- `data:` URL 形狀的字串被拒絕時，訊息說明它在到達工具之前已被解成二進位資料。
- `body` 的參數描述補上：有給就必須是字串。
- Example 補上空字串、`data:` URL、帳號不明確時的先後三列，「ending in send」改成測試實際檢查的內容；測試改用 `XCTUnwrap`。

## Non-Goals

- `to` 陣列（#733）、`from_address` 與其他工具的 `to`（#735）。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `message-composition`：MODIFIED Requirement: forward_email refuses a body that is not a string。

## Impact

- Affected specs: `message-composition`
- Affected code: `Sources/CheAppleMailMCP/Server.swift`
- Tests: `Tests/CheAppleMailMCPTests/ForwardBodyTypeTests.swift`
- Docs: `CHANGELOG.md`、`mcpb/manifest.json`
