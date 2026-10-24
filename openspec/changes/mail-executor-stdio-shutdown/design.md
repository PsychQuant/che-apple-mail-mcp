## Context

#329 的受控實驗證明 Mail actor 同步等待會佔住 cooperative worker；資源受限時，SDK transport 啟動與 EOF 都被延後。SDK 的 `waitUntilCompleted` 只等待 receive-loop task，並沒有等待啟動同步的結構化 join。

## Goals / Non-Goals

**Goals:** 阻塞 Mail 工作期間，stdio 能繼續握手及處理 EOF；保留 Mail actor 隔離與既有腳本控制。

**Non-Goals:** 不改 MCP SDK、不以 hard exit 或取消 mutation 縮短數字、不取消啟動同步、不承諾任意 OS 負載／檔案系統停滯下的即時保證；FDA race 留在 #422。

## Decisions

### Mail serial executor

採 [Swift SE-0392](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md) 的 custom actor executor：MailController 持有固定的 serial DispatchQueue executor，每個 job 在該 executor 執行一次。使用 `UnownedJob` 介面維持 macOS 13 編譯相容性。相較逐一把所有同步 script helper 改成 async，此做法保留既有 actor 方法、guard、preflight 與腳本執行器，只調整阻塞工作的排程位置。

### Real Server probe

測試將實際 app 的 object files（只排除 production main）連結成獨立 async-main probe，沿用真實 Server／SDK／StdioTransport。既有 script runner seam 產生 6 秒阻塞工作；新增 `databasePath` 初始化參數使用不存在的 fixture 路徑，預設仍為原 Mail index。probe 正常返回，不加 production test CLI、不強制退出成功路徑。所有 probe 子行程有外層失敗期限及 cleanup。

## Implementation Contract

`MailController.unownedExecutor` 必須一直指向 actor 持有的同一個 serial executor。每個 job 恰好執行一次；同步 script 呼叫不重疊，原錯誤及 timeout 行為保留。Server 的 production `init()` 呼叫與資料庫預設不變，只有測試可注入隔離路徑。

在 strict cooperative-pool、startup script 阻塞 6 秒的可控 fixture，真實 SDK 必須能在 2 秒內回應 initialize；關閉 stdin 後 probe 必須在 2 秒內以 rc=0 正常退出，且不依賴同步工作先完成。一般資源與 idle startup 都有控制組。2 秒是測試門檻，非所有 OS 負載下的產品即時 SLA。新增測試必須能在移除 actor executor 指定時失敗；現有 timeout、write-failure、staleness、Mail 方法測試需通過。

## Risks / Trade-offs

actor 工作轉至另一個 serial queue → 保留 actor 互斥，以並行呼叫測試驗證。job lifetime 與 executor identity → actor 強持有 executor、enqueue closure 保留 executor，避免 dangling unowned executor。GCD 排程非即時 → 不宣稱任意負載的硬上限。已送往 Mail 的 Apple Event 仍可能完成 → 不新增中斷／回滾承諾。

## Migration Plan

先提交 PR 與驗證證據；不自動部署／合併。無資料遷移。

## Open Questions

完整 IDD ensemble 待 Claude weekly quota 恢復。
