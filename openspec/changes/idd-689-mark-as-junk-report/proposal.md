## Problem

`mark_as_junk` 在 `is_junk` 為 false 時回 `Email marked as not junk`，信卻還在垃圾郵件匣。呼叫的人看到成功訊息會以為處理完了（#689）。

## Root Cause

工具只設定 Mail 的 `junk mail status` 屬性，然後回一個固定字串。這個屬性是旗標，不搬信；工具沒有讀回狀態，回傳訊息與工具描述也都沒有說明它不搬信。

## Proposed Solution

工具只改旗標這一點不變。設定之後讀回旗標，回傳訊息寫出讀回的值、說明這個工具沒有搬動信、信是在哪個信箱被指定的，以及要搬請呼叫 `move_email`。讀回的值與要求的相反時回報錯誤。讀不回來時照實說明，不當成錯誤。工具描述同步說明。

## Non-Goals

- 不讓 `mark_as_junk` 自己搬信：現有的呼叫者（例如 `/archive-mail` 的 Step 9）在之後自己呼叫 `move_email`。
- 不改 `move_email` 的回傳（#698）。
- 不在真的 Mail 帳號上驗證各種帳號類型的行為（#696）。

## Success Criteria

新的回報文字、相反讀回時的錯誤、script 的讀回與工具描述各有測試；`swift test` 全數通過。

## Impact

- Affected specs: junk-status-tool（新增）
- Affected code:
  - New: (none)
  - Modified:
    - Sources/CheAppleMailMCP/AppleScript/MutationToolScriptBuilder.swift
    - Sources/CheAppleMailMCP/AppleScript/MailController.swift
    - Sources/CheAppleMailMCP/Server.swift
    - Tests/CheAppleMailMCPTests/MutationToolScriptBuilderTests.swift
    - CHANGELOG.md
  - Removed: (none)
