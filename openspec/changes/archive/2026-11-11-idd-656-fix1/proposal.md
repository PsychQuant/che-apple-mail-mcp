## Summary

#656 第 1 輪 verify 的修正：規格寫出預設 VIP 路徑跟著 mail storage path 的測試 override（第 1 列，Blocking），收窄兩句過度宣稱（第 2、3 列），handler 測試裝上 script seam（第 4 列），Example 放到對的 Scenario（第 5 列）。

## Motivation

- 第 1 列（HIGH，依 #480 的規則）：沒有注入時，預設路徑現在由 `mailStoragePath` 組成，會跟著測試的 `mailStoragePathOverride`；requirement 只說家目錄的路徑與注入的路徑兩種。程式是刻意的（Diagnosis 的決定），正式執行時碰不到，但規格沒寫。nil 分支也只有靜態字串被釘住。
- 第 2 列：「伺服器……SHALL NOT 讀使用者的 VIP 清單」在 reader 沒開成時不成立：handler 會退回 AppleScript。
- 第 3 列：「讀不到或解析不了的清單 SHALL 列為空」超出這張 issue，把 #661 認為是 bug 的靜默 `[]` 寫成規格；「解析不了」也沒有測試。
- 第 4 列：`HandlerVIPListTests` 沒有裝 script seam，reader 萬一沒開成就會對 Mail 跑真的 AppleScript。
- 第 5 列：兩個 Example 放在 WHEN 不符的 Scenario 下。

## Proposed Solution

- requirement：預設讀 mail storage path 下的 `MailData/VIPMailboxes.plist`（沒有 override 時就是原本的檔案）；注入路徑時讀那個檔案，且開成的 reader 不讀使用者的清單；檔案不存在時列為空（拿掉「解析不了」）。
- Scenario 分成三個：注入路徑的 reader、注入路徑的伺服器、沒有注入的預設路徑；預設路徑另加一個經由 override 實際列出的 Example 與測試。
- `HandlerVIPListTests` 裝上會丟錯的 script seam，並斷言沒有 script 跑過。
- CHANGELOG 同步。

## Non-Goals (optional)

- 不改程式行為（`EnvelopeIndexReader` 與 `Server` 不動）。
- 讀取失敗的記錄與 AppleScript 退回在 #661；兩條路的回傳形狀在 #662；`runScriptAsList` 的 XCTest 守門在 #679。

## Impact

- Affected specs: `sqlite-query-engine`
- Affected code: `Tests/MailSQLiteTests/FilesystemQueryTests.swift`, `Tests/CheAppleMailMCPTests/HandlerVIPListTests.swift`, `CHANGELOG.md`
