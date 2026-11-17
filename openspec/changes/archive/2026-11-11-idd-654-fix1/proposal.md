## Summary

#654 第 1 輪 verify 的修正：凍結 `directDraftPath()` 的整段程式（第 1 列），並讓閘門 (3) 的規格句寫出它實際的行為（第 2 列）。

## Motivation

- 第 1 列（MEDIUM）：工廠是一個正式執行時會跑的變更點，測試沒有釘住它。原本的守門用 `source.contains` 且不看位置；把簽名覆寫移到 `guard let accountMapping` 之前可以編譯，正式執行時所有 `mail_default` 的直接寫入就會改走 GUI 路徑，而沒有測試轉紅。標記測試的簽名斷言也分不出覆寫與預設（預設對虛構的 `UUID-A` 也回 nil）。
- 第 2 列（LOW）：#654 加的規格句「閘門 (2)、(3) 每次都讀 AccountsMap.plist」對閘門 (3) 不精確：iCloud 的 Signatures 資料夾存在時，預設直接回「讀不到」，不讀 plist。CHANGELOG 與工廠的註解也這樣寫。

## Proposed Solution

- `IndexReaderWiringGuardTests` 逐行比對 `directDraftPath()` 的整段（去掉註解與縮排後），順序與內容都固定。
- 規格句改寫閘門 (3)：iCloud 簽名存在時回讀不到，否則讀 plist；加一個 Scenario 與 Example，由既有的 `testICloudSignaturesMakeTheLocalListUnknown` 加上標記來檢查。
- CHANGELOG 與工廠註解同步。

## Non-Goals (optional)

- 不改任何程式行為；不改 `DirectDraftPath.swift` 與 `AccountMapper`。
- 直接路徑的 handler 測試等 #660。

## Impact

- Affected specs: `message-composition`
- Affected code: `Tests/CheAppleMailMCPTests/IndexReaderWiringGuardTests.swift`, `Tests/CheAppleMailMCPTests/DirectDraftPathTests.swift`（只加標記）, `Sources/CheAppleMailMCP/Server.swift`（只改註解）, `CHANGELOG.md`
