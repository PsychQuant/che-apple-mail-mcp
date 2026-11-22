## Why

2026-11-22 對 iCloud 的 live 測試：`append_draft` 建的草稿，用回傳的 `message_id` 呼叫 `send_draft` 找不到（#752）。唯讀探測顯示 iCloud 的 `HEADER Message-ID` 搜尋只認帶角括號的完整值：帶角括號找得到，去掉角括號、只給 local part 都找不到。程式為了相容「標頭沒有角括號」而去掉角括號，在 iCloud 上就永遠找不到。

## What Changes

- 以 Message-ID 搜尋信匣時，一次查詢同時問帶角括號與不帶角括號兩種寫法（`OR HEADER Message-ID "<…>" HEADER Message-ID "…"`），命中後照舊完整比對。用到它的三處：`send_draft` 的 `message_id`／`draft_id`、寄件副本是否已存在、`append_draft` 結果不明時的查證。
- `send_draft` 結果的 `server_reply` 不再重複代碼（原本是 `250 250 2.0.0 Ok`）。

## Non-Goals

- 改用掃描整個信匣的 envelope。一次查詢就能涵蓋兩種伺服器，不需要。

## Capabilities

### Modified Capabilities

- `direct-transport`：以 Message-ID 搜尋的寫法。

## 前提

修改的 requirement 是 `idd-748-find-drafts-mailbox` 裡那一版（它又改自 744）。封存順序：742、744、745、748、752。

## Impact

- Affected specs: `direct-transport`（修改「send_draft sends one existing draft and cannot write content」）
- Affected code: `Sources/CheAppleMailMCP/DirectTransport/SwiftMailSession.swift`
- Tests: `Tests/CheAppleMailMCPTests/SubmitOutcomeClassificationTests.swift`
- Docs: `CHANGELOG.md`
