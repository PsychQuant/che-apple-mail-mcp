## Summary

讓 `create_draft` 的直接寫入路徑在伺服器帶著注入的帳號對照（`accountMapping`）建立時，從那份對照回答帳號閘門，不讀這台機器的 AccountsMap.plist（#654）。

## Motivation

#633 讓帶著 `accountMapping` 建立的伺服器，處理 `account_name` 時只讀測試給的對照。但 `create_draft` 建 `DirectDraftPath` 時沿用兩個預設閉包，`accountUUIDs` 與 `accountSignatureIDs` 都讀這台機器的 AccountsMap.plist，所以走到直接寫入路徑的 handler 測試會讀到開發者自己的帳號。目前沒有測試走到這裡（直接寫入需要環境變數，版本閘門也在前面），是潛在的暴露。

## Proposed Solution

- 伺服器加一個 `directDraftPath()`：沒有對照時回傳與現在完全相同的 `DirectDraftPath(controller:reader:)`；有對照時另外設定 `accountUUIDs` 從對照回答、`accountSignatureIDs` 回 nil（對照裡沒有簽名清單；讀不到清單本來就讓 `mail_default` 走 GUI 路徑）。`create_draft` 改用它。
- 規格：Requirement: Direct-write draft path 的閘門 (2)、(3) 寫出有對照時從哪裡回答。
- 測試：工廠在有對照時的兩個閉包；以及原始碼守門：`Server.swift` 裡唯一的 `DirectDraftPath(` 在工廠裡、注入的查詢只用對照。

## Non-Goals (optional)

- 不改 `DirectDraftPath.swift` 的兩個閉包預設值（`DirectDraftPathTests` 釘住它們）、凍結段與 `MailSQLite`。
- 寫入器的 `databasePath`（預設是這台機器的 Envelope Index）不在範圍內。
- 不讓 handler 測試真的跑完直接寫入路徑（需要環境變數與版本閘門）。

## Alternatives Considered (optional)

- 在 `DirectDraftPath` 裡讀伺服器的對照：要改凍結段附近的程式與被釘住的預設值，範圍較大。

## Impact

- Affected specs: `message-composition`
- Affected code: `Sources/CheAppleMailMCP/Server.swift`, `Tests/CheAppleMailMCPTests/HandlerAccountMappingTests.swift`, `Tests/CheAppleMailMCPTests/IndexReaderWiringGuardTests.swift`, `CHANGELOG.md`
