## Why

`get_mail_log_events` 的簡短模式（`detail=brief`）只能用 `categories` 縮小範圍。`IMAPConnection`、`IMAPSyncActivity` 這類 category 在 4 秒內就超過 200 筆，要找「上傳回條有沒有出現」這種單一事件，只能縮短窗口或一頁一頁翻，而這正是這個工具最主要的用途（#466，來自 #465 的實機驗證）。`contains` 只開放給詳細模式，因為在簡短模式它會變成探測識別資訊的 oracle，所以不能拿它來解。

## What Changes

- `get_mail_log_events` 新增參數 `events`：1 到 20 個字串，每個 1 到 1024 個 UTF-8 bytes，重複值合併。只保留「輸出時顯示的 `event` 值」與其中一個字串**完全相等**（區分大小寫）的事件；不做子字串或前綴比對。簡短與詳細模式都可用，和 `contains` 同時給時兩者都要符合。
- 比對對象是輸出時顯示的事件名，不是原始 `formatString`：被收回的模板只能以 `<template withheld>` 被選到，訊息過長的事件以其原始模板被選到，上傳回條以 `imap.append_uid_received` 被選到。顯示名稱與篩選共用同一個函式，兩者不會分岔。
- 以 `imap.` 開頭、卻不是已知事件名稱的值，在啟動讀取器之前就回 invalid-parameter 錯誤，避免打錯字被讀成「事件沒發生」。
- 篩選套用在與 `contains` 相同的位置：在 scan frontier 更新之後、`offset` 跳過之前，所以 `next_offset` 與 `offset` 只計算符合篩選的事件，`scan_cap`／`deadline` 停止時的 cursor 仍是 scan frontier。
- 回應新增 `events` 欄位：有給篩選時是正規化後（去重、保留順序）的陣列，沒給時是 `null`；查無結果時的 `notice` 說明篩選已套用。
- 工具描述、參數 schema、`README.md` 與 `README_zh-TW.md` 的工具列改寫，移除「還沒有依事件名稱篩選」的敘述。

## Non-Goals

- 不新增已知事件。`KnownEvents` 維持恰好一項（`imap.append_uid_received`）；這個篩選不是擴充它的理由。
- 不把 `events` 傳進 `log show` 的 predicate：篩選在解析之後進行，掃描量不會變少，改善的是 `limit` 與翻頁只計算符合的事件。
- 不修改 `add-mail-log-events` 這個尚未封存的 change。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `mail-log-diagnostics`：新增一條 requirement（brief／detailed 的事件名稱篩選）。這個 capability 目前只存在於尚未封存的 change `add-mail-log-events`，`openspec/specs/` 裡還沒有它，所以本 change 只用 ADDED requirement，不改寫既有 requirement 的文字。

ASSUMPTION: 上限取 1024 bytes 而不是 diagnosis 建議的 200 字元，因為 1024 bytes 是能被顯示的模板長度上限（更長的模板一律收回），200 字元會讓部分真實模板無法被選到。
ASSUMPTION: 不禁止控制字元：值只在解析後與顯示名稱做相等比較，永遠不會進到讀取器的 predicate，含換行的真實模板也要能被選到。

## Impact

- Affected specs: `mail-log-diagnostics`（ADDED requirement）
- Affected code:
  - `Sources/CheAppleMailMCP/MailLog/MailLogQuery.swift`（參數、驗證、`allowedParameters`）
  - `Sources/CheAppleMailMCP/MailLog/MailLogService.swift`（共用顯示名稱函式、掃描迴圈中的篩選、回應的 `events` 與 notice）
  - `Sources/CheAppleMailMCP/MailLog/MailLogTool.swift`（schema 與描述）
  - `Tests/CheAppleMailMCPTests/MailLog/`（新測試檔與 `MailLogToolTests` 的描述釘選）
  - `README.md`、`README_zh-TW.md`
