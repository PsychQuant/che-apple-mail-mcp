## Summary

讓 `list_vip_senders` 讀的 VIP 清單路徑可以注入（#656）：沒注入時讀的檔案與現在相同，handler 測試只讀測試自己給的檔案。

## Motivation

`EnvelopeIndexReader.listVIPSenders()` 每次都從使用者家目錄組出 `~/Library/Mail/V10/MailData/VIPMailboxes.plist`，沒有參數也不走已有測試 override 的 `mailStoragePath`。所以 `list_vip_senders` 的 handler 測試會讀到開發者自己的 VIP 清單（沒有清單的機器則是空的），測試結果取決於機器——#612、#633 為 AccountsMap.plist 移除過同一種暴露。目前沒有測試這樣做；唯一的 `testListVIPSenders` 跑真的 index、什麼都不斷言。

## Proposed Solution

- `EnvelopeIndexReader.init` 加 `vipMailboxesPath: String? = nil` 並存起來；`listVIPSenders()` 讀它，nil 時讀 `defaultVIPMailboxesPath`（`mailStoragePath` 加 `/MailData/VIPMailboxes.plist`）。沒有 override 時這就是原本寫死的那個路徑。
- 伺服器 `init` 加同名參數，在 `open:` 閉包裡傳給 reader，與 `accountMapping` 一樣（#612）。
- 規格：Requirement: List VIP senders via filesystem 寫出注入路徑的行為，以及讀不到清單時是空的。
- 測試：reader 層（不需真的 index）與 handler 層各一，外加預設路徑的釘住測試。

## Non-Goals (optional)

- 讀取失敗時靜默回 `[]` 與 SQLite／AppleScript 兩條路回傳形狀不同，是 Diagnosis 記下的姊妹候選，不在這裡。
- reader 為 nil 時 handler 退回 AppleScript 的既有行為不變。

## Impact

- Affected specs: `sqlite-query-engine`
- Affected code: `Sources/MailSQLite/EnvelopeIndexReader.swift`, `Sources/CheAppleMailMCP/Server.swift`, `Tests/MailSQLiteTests/FilesystemQueryTests.swift`, `Tests/CheAppleMailMCPTests/HandlerVIPListTests.swift`, `CHANGELOG.md`
