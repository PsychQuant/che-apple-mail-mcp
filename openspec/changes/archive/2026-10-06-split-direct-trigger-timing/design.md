## Context

- **現況**：直接寫入的觸發由 `MailController.triggerDirectDraftUpload(rowId:)` 執行：`runDraftScanScript(buildDirectDraftTriggerScript(rowId:), timeout: 20)` → `runSubprocessScript`（osascript 子程序，含 Automation 預檢）。swift 端只在觸發返回後記一個 `trigger_sent`，所以 `inserted` → `trigger_sent` 的 1.67 秒是一整塊。
- **可沿用的機制**：GUI 路徑的計時點已在用。`ComposeTiming.prelude` 加上 `markStatement(label)` 會讓 script 在 stderr 寫出 `CHE_MAIL_TIMING|<label>|<秒>`。只要計時開啟（`ComposeTiming.isEnabled`），transport 就把每個 osascript 子程序的 stderr 交給 `ComposeTiming.captureStderr`（`MailController.swift:441`），放進**process 全域** buffer；GUI 的 `recordComposeTiming` 再用 `takeCapturedMarks()` 取走，得到 `source` 為 `script` 的 `Mark`。
- **約束**：
  - compose-timing spec 規定計時關閉時，產生的 AppleScript 與沒有計時支援時逐位元組相同；
  - 交易安全規則第 8 項要求兩次已讀切換之間的間隔不變，#490 的守門測試解析觸發 script 檢查這一點；
  - `attemptSteps` 從 `timer.mark("inserted")` 到函式結尾被 #490 整段凍結，`ensureRead` 與 `attemptSteps(` 的使用位置也被釘住。

## Goals / Non-Goals

**Goals:**

- 把觸發拆成可量測的子步驟，計時列與既有的 `direct` 段落在同一個 run。
- 計時關閉時行為與 script 完全不變。
- 觸發的 script 計時點不會留在全域 buffer 裡，被之後的 GUI 段落誤收。

**Non-Goals:**

- 加速、改間隔或改等待（#488、後續 issue）。
- 重新設計全域 capture buffer（#483）。
- 細分 Automation 預檢與子程序啟動。

## Decisions

### D1：script 計時點的位置

計時開啟時，觸發 script 以 `ComposeTiming.prelude` 開頭，並在下列位置各加一行 `my _cheMailMark("<label>")`：

| label | 位置 |
|---|---|
| `trigger_script_start` | `tell application "Mail"` 之後的第一行 |
| `trigger_listed` | 輪詢迴圈結束、`if _m is missing value then error …` 之後（確定找到草稿） |
| `trigger_unread` | `set read status of _m to false` 之後、`delay 0.5` 之前 |
| `trigger_read` | `set read status of _m to true` 之後、`return "toggled"` 之前 |

- 兩次切換之間只多 `trigger_unread` 這一行，沒有 `delay` 也沒有控制流程，所以 #490 的第 8 項守門測試仍讀得到 0.5 秒。計時呼叫本身的時間只會讓實際間隔變長。
- 找不到草稿時 script 在 `trigger_listed` 之前就 `error`，所以不會有 `trigger_listed` 以後的列，符合「沒完成的步驟不產生列」。

替代方案：在 swift 端拆成多次 osascript 呼叫，各自計時。**否決**，因為這會改變被量測的對象（多出子程序啟動），也會改動被凍結的觸發流程。

### D2：計時旗標怎麼傳

- `buildDirectDraftTriggerScript(rowId:timing:)` 的 `timing` 預設值為 `ComposeTiming.isEnabled`，與 GUI builder 的寫法一致。
- `triggerDirectDraftUpload(rowId:timing:)` 由呼叫端傳入 `timer.isRecording`（`DirectDraftTimer` 有 run 時為 true）。只有在 script 計時點有地方放時，才產生計時版 script。
- 計時關閉時呼叫 `buildDirectDraftTriggerScript(rowId:timing: false)`，輸出與現在逐位元組相同（測試鎖住）。

### D3：在哪裡、何時取走 script 計時點

`attemptSteps` 在觸發返回之後、以及在 `catch` 的第一行，各呼叫一次 `timer.absorbScriptMarks()`：

- 這個方法呼叫新增的 `ComposeTiming.takeCapturedMarks(where:)`，在同一個鎖內只移出 label 以 `trigger_` 開頭的點，其他點留在 buffer 裡，不吞掉別人的資料；
- 移出的點（`source` 為 `script`）併入 `DirectDraftTimer`。

取走的時機在 `trigger_sent` 之前，所以成功與失敗兩條路徑都不會把觸發的計時點留給之後的 GUI 段落（直接寫入失敗退回 GUI 時，同一個 run 接著會記 GUI 的列）。

替代方案：讓 transport 依呼叫者分開 buffer。**否決**，那是 #483 的範圍。

### D4：swift 端的 `trigger_spawn`

`timer.mark("trigger_spawn")` 記在 `let triggered = Date()` 之後、`do {` 之前，也就是把上傳請求交給 `triggerDirectDraftUpload` 之前。所以 `trigger_spawn` 到 `trigger_script_start` 包含 Automation 預檢、osascript 啟動與 Mail 收到 Apple event 的時間；本改動不再細分。

### D5：#490 守門測試的同步

`attemptSteps` 凍結段多了 `trigger_spawn` 一行與兩次 `absorbScriptMarks()`，`triggerDirectDraftUpload` 的呼叫也多了 `timing:` 參數，所以凍結副本在同一個 commit 更新。第 8 項守門測試加一條：對 `buildDirectDraftTriggerScript(rowId:timing: true)` 同樣要求間隔 ≥ 0.5 秒。

## Risks / Trade-offs

- **[量測本身的成本]** ASObjC prelude（`use framework "Foundation"`）可能讓觸發本身變慢 → 分析時同時報告計時開／關兩種模式的 `inserted` 到 `trigger_sent` 總時間，標明量測帶來的成本。
- **[全域 buffer 的競爭]** 同一個 process 內若有另一個呼叫同時在跑 osascript，它的計時點可能被這裡取走；反過來，這裡的點也可能被它取走 → 只移出 `trigger_` 前綴的點、其他點留在 buffer，可以降低但不能消除這個風險，通盤修法在 #483。
- **[凍結副本更新]** 守門測試會因本改動轉紅，必須同步更新 → 審查時逐行對照規則第 2、3、6、7 項。本改動只新增計時呼叫，不改等待與補設已讀。

- **[逾時不留計時點]** 觸發逾時（20 秒）或 osascript 的輸出管線沒有關閉時，transport 在擷取 stderr 之前就拋錯，所以這兩種失敗連已經寫出的 script 計時點都不會進 buffer，段落裡只會有 `trigger_spawn`。這不會殘留，但最需要量測的卡住情況反而看不到子步驟；要改得動 transport，不在本改動範圍。

## Migration Plan

不需要遷移。計時 CSV 的欄位不變，只是 `direct` 段落多了幾列。舊檔可以照常追加。

## Open Questions

(none)
