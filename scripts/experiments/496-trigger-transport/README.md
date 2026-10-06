# #496：觸發的傳輸方式（subprocess 與 in-process）量測

直接寫入的上傳觸發，現在是啟動 `/usr/bin/osascript` 執行 script（subprocess）。#489 量到 `trigger_spawn → trigger_script_start` 中位數 198 ms，這張要回答三件事：這段時間花在哪裡；改成 in-process 能省多少；改了是否安全。

## 結論

1. **不改傳輸方式。**
   - in-process 送一次唯讀 Apple event 只要 0.3–6.6 ms。subprocess 的「啟動 osascript、送一次 Apple event」最快一群約 68–72 ms，中位數約 144 ms。
   - 以這個單行 script 推算，每次約可省 65–140 ms，約為整次 `create_draft`（中位數 2.7 秒，#489）的 2–5%。
   - 但真實的觸發 script 不是單行。#406 記錄過：同一份多事件 script，在 osascript 裡幾秒完成，在背景 `NSAppleScript` 卻超過 50 秒。所以改成 in-process 對觸發 script 未必更快。
   - 更重要的是安全性。subprocess 逾時時會要求終止 osascript，確認結束後 script 就不再執行；in-process 沒有任何終止機制，逾時只能放棄執行它的 thread，script 仍會在背景繼續送 Apple event。觸發逾時後我們會還原寫入（規則第 2 項），背景的 script 卻可能之後才切換已讀，這削弱了第 2、3 項的前提。
   - 依 `.claude/rules/direct-write-transaction-safety.md`，任何一項被削弱就不做。
2. **#489 的 198 ms 有相當一部分是計時本身，但份額只能推估。**
   - 計時開啟時，script 開頭有 `use framework "Foundation"`（`ComposeTiming.prelude`），osascript 每次都要載入 ASObjC bridge。同一負載下，加上 prelude 的條件 (d) 比不加的 (c) 多約 290 ms（最快一群：359 對 68–72 ms；中位數：432–434 對 144 ms）。
   - 不開計時時，傳輸成本估計為：預檢約 10 ms，加上啟動 osascript 並送一次 Apple event 約 70–144 ms（最快一群到中位數），合計約 80–155 ms。
   - 拿 #489 的 198 ms 減去這個範圍，計時本身約佔 45–120 ms。這是**跨負載相減的推估**：#489 在較低負載下量，本實驗在 load 118–139 下量。本實驗直接量到的 prelude 成本（約 215–290 ms）甚至大於 #489 的整段，可見負載對各段的放大倍率不同。
   - 能確定的只有方向：計時開啟時，prelude 是這一段的主要成本之一。所以 #489 起、計時開啟時量到的觸發時間，都比計時關閉的正式路徑多了一段計時本身的成本。
   - 規則表裡 2026-10-05 的計時數字（觸發 1,667 ms）不受影響：當時直接寫入的觸發 script 還沒有計時點，也沒有 prelude（`buildDirectDraftTriggerScript(rowId:)`，#489 之前）。
3. **附帶發現（#499）**：權限預檢偶爾會誤報「Mail 沒在執行」，兩輪 66 次中出現 5 次。

## 檔案

| 檔案 | 內容 |
|---|---|
| `bench.swift` | 量測 harness。不建草稿，唯一送出的 Apple event 是唯讀的 `tell application "Mail" to get name`。開始量測前先做與 server 相同的權限預檢，沒有授權就退出（見〈harness 的安全性〉）。 |
| `results-run1.json` | 第 1 輪原始結果（n = 30／條件）。load 沒有寫進檔案；跑完當下 `uptime` 顯示 117.7。 |
| `results-run2.json` | 第 2 輪原始結果（n = 30／條件；load 124.6 → 138.8，記在 `meta`）。 |

## 方法

六個條件。每輪先跑 3 輪暖機（不計入），之後每輪隨機打亂六個條件的順序，避免時段漂移只落在某個條件上。

| 條件 | 內容 | 對應正式路徑的哪一段 |
|---|---|---|
| (a) | `AutomationStatus.probe()` 的同一組呼叫：`NSRunningApplication`，加上 `AEDeterminePermissionToAutomateTarget` | `preflightAutomation()` 的權限預檢（不含它另外讀的版本 sidecar） |
| (b) | `osascript -` 執行 `return 1`（stdin 餵 script，兩條 thread 並行排空輸出） | 啟動與編譯，不送 Apple event |
| (c) | `osascript -` 執行 `tell application "Mail" to get name` | 啟動、編譯，加一次 Apple event |
| (d) | 同 (c)，前面加上 `ComposeTiming.prelude` 與一次 mark；另記「啟動到第一個 mark」 | 計時開啟時的觸發前段，與 #489 的 `trigger_spawn → trigger_script_start` 對應 |
| (e) | in-process：背景 thread 每次 `NSAppleScript(source:)` 加執行（main thread 先 prime，同 #471） | `MailController.runScript` 的形狀 |
| (f) | in-process：預先編譯一次，背景 thread 重複執行 | in-process 的下限 |

subprocess 與 in-process 的每次執行都檢查回傳值（要回 `1` 或 `Mail`，in-process 另要求沒有錯誤），失敗就中止，不讓「失敗後很快返回」被當成「很快」。(a) 例外：它記錄每次回傳的狀態，不因單次非 0 中止（見〈其他觀察〉）。

## 結果（2026-10-06，macOS 27.2.0，Mail 16.0，每輪 n = 30）

| 條件 | 第 1 輪中位數（範圍） | 第 2 輪中位數（範圍） | 最快一群（第 1 輪／第 2 輪） |
|---|---|---|---|
| (a) 權限預檢 | 9.7 ms | 9.8 ms | — |
| (b) 啟動、`return 1` | 71.8（63.7–217.5） | 71.9（64.1–154.1） | 24/30 筆，中位數 71.1 ／ 20/30 筆，68.5 |
| (c) 啟動、`get name` | 144.0（64.7–148.9） | 143.6（64.2–222.1） | 8/30 筆，68.0 ／ 10/30 筆，71.9 |
| (d) 加計時 prelude | 432.4（353.2–658.0） | 433.9（352.2–654.4） | 9/30 筆，359.4 ／ 4/30 筆，360.2 |
| (d) 啟動到第一個 mark | 317.4（265.8–506.8） | 321.1（258.9–538.6） | 11/30 筆，284.3 ／ 7/30 筆，283.3 |
| (e) in-process 每次編譯 | 2.6（1.6–5.9） | 2.9（1.4–6.6） | — |
| (f) in-process 預先編譯 | 0.8（0.4–2.8） | 0.8（0.3–3.6） | — |

「最快一群」：(b)、(c) 取 ≤ 100 ms，(d) 取 ≤ 400 ms，「啟動到第一個 mark」取 ≤ 300 ms。

## 怎麼讀這些數字

- **量測時機器負載很重**：load 約 118–139，來源是其他應用程式與其他工作，不是本實驗。
- **subprocess 的時間成階狀分布**：集中在約 70 ms 的整數倍（64–73、141–149、217）。原因沒有確定，有兩種可能：
  - 負載下的排程延遲；
  - Apple event 路徑在 subprocess 下真的多出一階，例如 osascript 向 LaunchServices 解析 Mail。量測時 LaunchServices 正忙（見〈其他觀察〉）。
- **(b) 與 (c) 的差別是真的，不是雜訊。**
  - 最快一群裡兩者幾乎相同（約 68–72 ms）。
  - 但 (c) 只有 8/30 與 10/30 落在最快一群，(b) 是 24/30 與 20/30；中位數 (c) 約 144 ms，(b) 約 72 ms，兩輪都重現。
  - 所以「多送一次 Apple event」在 subprocess 下多數時候會多出約 70 ms。in-process 的同一次往返只要 0.3–6.6 ms，所以這一階是 subprocess 端的成本。
- **因此本文的節省量與傳輸成本都寫成範圍**：最快一群是下限，中位數是本負載下的典型值。

## 對照交易安全規則的 8 項（in-process 觸發）

| 項目 | 是否受影響 | 理由 |
|---|---|---|
| 1 單一交易 | 否 | 寫入在觸發之前已 commit |
| 2 觸發前精確還原 | **是** | 逾時後只能放棄 thread，script 仍在背景執行。我們還原了寫入，script 卻可能之後才切換已讀 |
| 3 觸發後不退回 | **是** | 還原後會改走 GUI 路徑。背景 script 若在還原之後才切換已讀，Mail 可能仍依它記憶體裡的那封草稿上傳，加上 GUI 路徑建立的那封就是兩份 |
| 4 寫入前閘門 | 否 | 與觸發傳輸無關 |
| 5 不碰 Mail 的欄位 | 否 | 同上 |
| 6 只陳述觀察到的事 | 否 | 回報邏輯不變 |
| 7 上傳確認與補設已讀 | 否 | 不變 |
| 8 切換間隔 | 否 | script 內容不變 |

第 2、3 項的失敗情境是推論，沒有實測。

**兩種傳輸的差別是程度，不是有無。** `MailController.runSubprocessScript` 逾時時要求終止 osascript（先 SIGTERM，再 SIGKILL），並觀察它是否結束：
- 確認結束後，script 不會再送出新的 Apple event；
- 但已被 Mail 接受的事件仍可能完成（#415）；
- 兩次都無法確認結束時（例如 Mail 卡住，子行程處於不可中斷的等待），子行程被記為未回收（`markUnreaped`，#417），script 是否停下來也無法保證。

in-process 則完全沒有終止機制：AppleScript 的 `with timeout` 只限制等待單一回應的時間，無法從外部中止整段 script，而且 #297、#362 都記錄過被放棄的 thread 造成的問題。所以改成 in-process 會讓「上傳請求成功或失敗」更不確定，不是更確定。

結論是**不做**。可省的時間不足以支持另開實驗去設計可中止的 in-process 傳輸：單行 script 推算每次約 65–140 ms，而對多事件的觸發 script 是否真的會變快，還有 #406 的反向證據。

## harness 的安全性

- **開始量測前的檢查**：先呼叫 `probe()`。Mail 沒在執行、或權限狀態不是 `noErr`，就以 2 結束，不送任何 Apple event。`AEDeterminePermissionToAutomateTarget` 的 `askUserIfNeeded` 傳 `false`，檢查本身不會跳出授權視窗。
- **之後不再逐次檢查授權**：Automation 授權一旦是「已授權」，之後只會因使用者撤銷而變成「拒絕」，這時 Apple event 會直接失敗（-1743），不會跳出視窗。授權視窗只在「未決定」時出現，而開始前的檢查已排除這個狀態。
- **(a) 的延遲樣本包含提早返回的預檢**：兩輪共 5 次回報 Mail 沒在執行，這幾次幾乎不花時間（最小值 0.0 ms），也算在 (a) 的樣本裡。中位數不受影響。
- **(d) 的「啟動到第一個 mark」**：只有在 stderr 找得到並解析出 mark 時才記錄；解析失敗不會中止。兩輪最後都留下 30 筆，但無法從檔案判斷暖機輪是否全部解析成功。

## 其他觀察

- **權限預檢偶爾誤報「Mail 沒在執行」**：第 1 輪 1/33 次，第 2 輪 4/33 次（含暖機）。量測期間用 `ps` 看到 `launchservicesd` 約 39% CPU；這個數字沒有寫進結果檔。harness 的 main thread 在兩次預檢之間被 semaphore 卡住，與 server 不同，所以 server 是否也會遇到還沒確認，記錄在 #499。
- **in-process 在背景 thread 確實拿得到 Mail 的回應**：main thread 先 prime 之後，背景 thread 執行 `get name` 回傳 `Mail`、沒有錯誤，與 #471 修正後的行為一致。

## 限制

- **高負載。** 兩輪都在 load 118–139 下量，沒有低負載時的重跑。
- **授權主體不同。** harness 從終端機啟動，Automation 授權屬於終端機，不是簽章的 server binary。啟動 osascript 與 Apple event 的成本應相同，但沒有用 server binary 驗證。
- **script 不同。** 只量了一行唯讀的 `get name`，不是觸發 script 本身。觸發 script 要等 Mail 列出草稿、做兩次切換與 0.5 秒間隔（見 #489、#488）；in-process 對多事件 script 的表現有 #406 的反向證據。
- **in-process 的編譯成本會隨 script 長度增加**：(e) 用的是一行 script。

## 重跑

```bash
swiftc -O -o /tmp/bench496 scripts/experiments/496-trigger-transport/bench.swift
/tmp/bench496 30 /tmp/results.json   # Mail 必須在執行，且終端機已有 Mail 的 Automation 授權
```

harness 會在送出任何 Apple event 之前確認授權。沒有授權時印出原因並以 2 結束，不會跳出授權視窗。
