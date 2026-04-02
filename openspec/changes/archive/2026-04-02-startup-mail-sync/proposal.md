## Why

MCP server 讀取路徑已完全改為 filesystem（SQLite + .emlx），不依賴 AppleScript。但 SQLite Envelope Index 的資料只在 Mail.app 運作時才會更新。如果使用者沒有開著 Mail.app，查到的是上次關閉時的快照，可能落後數小時。

使用者每次查詢都預期看到最新的郵件。

## What Changes

MCP server 啟動時（`init()` 完成、handlers 註冊後），以 fire-and-forget 方式呼叫 AppleScript `check for new mail`。這會：
1. 如果 Mail.app 沒開 → 啟動 Mail.app 並觸發全帳號同步
2. 如果 Mail.app 已開 → 觸發一次額外的同步檢查

此呼叫在背景 `Task {}` 中執行，不阻塞 MCP `initialize` 回應。

## Non-Goals

- 不加定時 timer — Mail.app 啟動後自身的 IDLE/fetch 機制會接手持續同步
- 不在每次查詢前觸發同步 — 會重新引入 AppleScript 阻塞到讀取路徑
- 不等待同步完成 — fire-and-forget，不影響 server 啟動速度

## Capabilities

### New Capabilities

（無新 capability — 這是啟動行為的增強）

### Modified Capabilities

（無）

## Impact

- Affected code: `Sources/CheAppleMailMCP/Server.swift` — `init()` 方法尾部加一行 `Task {}`
