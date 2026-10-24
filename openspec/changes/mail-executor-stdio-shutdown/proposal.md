## Why

#329 的啟動同步會在 Mail actor 的 cooperative executor 執行緒上等待 semaphore；資源受限時，transport 連開始讀取 stdin 都會被延後。SDK 的完成等待並沒有直接等待同步工作。

## What Changes

- MailController 改用獨立 DispatchQueue serial executor，保留 actor 隔離與既有同步腳本呼叫介面。
- 保留啟動同步、45 秒腳本 guard、GUI／subprocess／staleness 規則；不以強制退出掩蓋延遲。
- 新增實際 Server／SDK 的 pipe 子行程測試與序列性控制組。
- Server 接受可注入的 databasePath，讓測試使用不存在的 fixture 路徑而非使用者 Mail index。

## Capabilities

### New Capabilities

- `stdio-mail-executor-isolation`: 阻塞 Mail 工作與 stdio 協定進度的 executor 隔離。

### Modified Capabilities

無。

## Impact

MailController、獨立 serial executor、Server 初始化參數、stdio regression tests 與舊關閉延遲註解。無新 MCP 參數或部署變更。
