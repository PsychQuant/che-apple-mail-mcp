## 1. 實作

- [x] 1.1 在 `Server.swift` 的 `init()` 方法中，`await registerHandlers()` 之後加入 `Task { try? await mailController.checkForNewMail() }` 作為 fire-and-forget 背景同步

## 2. 驗證

- [x] 2.1 MCP server 啟動測試：確認 initialize 回應仍在 1 秒內完成（背景 Task 不阻塞）
- [x] 2.2 手動驗證：啟動 server 後確認 Mail.app 被啟動並開始同步
