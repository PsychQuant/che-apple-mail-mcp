# #496：觸發的傳輸方式（subprocess 與 in-process）量測

直接寫入的上傳觸發，現在是啟動 `/usr/bin/osascript` 執行 script（subprocess）。#489 量到 `trigger_spawn → trigger_script_start` 中位數 198 ms，這張要回答三件事：這段時間花在哪裡；改成 in-process 能省多少；改了是否安全。

## 結論

1. **不改傳輸方式。**
   - in-process 送 Apple event 確實快很多：每次 1–6 ms，subprocess 最快一群約 68–72 ms，每次可省約 65–70 ms。
   - 但 in-process 逾時時只能放棄執行它的 thread，script 會在背景繼續送 Apple event。觸發逾時後我們會還原寫入（規則第 2 項），背景的 script 卻還可能切換已讀，這削弱了第 2、3 項的前提：「上傳請求成功或失敗」必須是一個確定的事實。
   - 依 `.claude/rules/direct-write-transaction-safety.md`，任何一項被削弱就不做，不論省下多少時間。
2. **#489 的 198 ms 大部分是計時本身。**
   - 計時開啟時，script 開頭有 `use framework "Foundation"`（`ComposeTiming.prelude`），osascript 每次都要載入 ASObjC bridge。
   - 不開計時時，傳輸成本約 80 ms：權限預檢約 10 ms，加上啟動 osascript 並完成第一次 Apple event 約 70 ms。
   - 拿 #489 的 198 ms 減去這 80 ms，計時本身約佔 120 ms。
   - 所以 #489 計時開啟量到的觸發時間，比正式路徑多約 0.1 秒。
3. **附帶發現（#499）**：權限預檢偶爾會誤報「Mail 沒在執行」，兩輪 66 次中出現 5 次。

## 檔案

| 檔案 | 內容 |
|---|---|
| `bench.swift` | 量測 harness。不建草稿，唯一送出的 Apple event 是唯讀的 `tell application "Mail" to get name`；送出任何 Apple event 之前，先做與 server 相同的權限預檢，沒有授權就退出，所以不會跳出授權視窗。 |
| `results-run1.json` | 第 1 輪原始結果（n = 30／條件；load 未寫進檔案，跑完當下 `uptime` 為 117.7） |
| `results-run2.json` | 第 2 輪原始結果（n = 30／條件；load 124.6 → 138.8，記在 `meta`） |

## 方法

六個條件。每輪先跑 3 輪暖機（不計入），之後每輪隨機打亂六個條件的順序，避免時段漂移只落在某個條件上。

| 條件 | 內容 | 對應正式路徑的哪一段 |
|---|---|---|
| (a) | `AutomationStatus.probe()` 的同一組呼叫：`NSRunningApplication`，加上 `AEDeterminePermissionToAutomateTarget` | `preflightAutomation()` |
| (b) | `osascript -` 執行 `return 1`（stdin 餵 script，兩條 thread 並行排空輸出） | 啟動與編譯，不送 Apple event |
| (c) | `osascript -` 執行 `tell application "Mail" to get name` | 啟動、編譯，加一次 Apple event |
| (d) | 同 (c)，前面加上 `ComposeTiming.prelude` 與一次 mark；另記「啟動到第一個 mark」 | 計時開啟時的觸發前段，與 #489 的 `trigger_spawn → trigger_script_start` 對應 |
| (e) | in-process：背景 thread 每次 `NSAppleScript(source:)` 加執行（main thread 先 prime，同 #471） | `MailController.runScript` 的形狀 |
| (f) | in-process：預先編譯一次，背景 thread 重複執行 | in-process 的下限 |

每次都檢查回傳值：subprocess 要回 `1` 或 `Mail`，in-process 要回 `Mail` 而且沒有錯誤。失敗就中止，不讓「失敗後很快返回」被當成「很快」。

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
  - subprocess 的時間明顯量子化，集中在約 70 ms 的整數倍（64–73、141–148、217）。這是排程延遲，不是 osascript 本身的成本，所以中位數偏高。
  - 「最快一群」是兩輪中都穩定出現的下限，最接近不受干擾時的值。
- **一次 Apple event 本身很便宜。** 最快一群裡 (b) 與 (c) 幾乎相同（約 68–72 ms），in-process 往返只要 1–6 ms。subprocess 的成本幾乎全在啟動 osascript。
- **計時 prelude 是最大的一段。**
  - 最快一群裡 (d) 比 (c) 多約 290 ms；「啟動到第一個 mark」比 (b) 多約 215 ms。
  - 這些是高負載下的數字。#489 當時的整段（含預檢）只有 198 ms，所以當時的負載較低，prelude 的成本也較低。
  - 本次的絕對值不能直接拿來和 #489 比，但方向一致：prelude 是計時開啟時這一段的主要成本。
- **不開計時的傳輸成本約 80 ms**，即預檢約 10 ms 加最快一群約 70 ms。這是推估：本實驗沒有在負載低時重跑。

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

subprocess 的逾時處理是要求終止 osascript：之後不會再送出新的 Apple event。已經送出的事件 Mail 仍會處理，這在兩種傳輸下都一樣，但 subprocess 至少能保證 script 停下來。in-process 沒有對應的機制：AppleScript 的 `with timeout` 只限制等待單一回應的時間，無法從外部中止整段 script；而且 #297、#362 都記錄過放棄的 thread 造成的問題。

所以結論是**不做**。可省的時間（每次約 65–70 ms，約整次 `create_draft` 的 2–3%）也不足以支持另開實驗去設計可中止的 in-process 傳輸。

## 其他觀察

- **權限預檢偶爾誤報「Mail 沒在執行」**：第 1 輪 1/33 次，第 2 輪 4/33 次。
  - 同時段 `launchservicesd` 約 39% CPU；
  - harness 的 main thread 在兩次預檢之間被 semaphore 卡住，與 server 不同。

  server 是否也會遇到還沒確認，記錄在 #499。
- **in-process 在背景 thread 確實拿得到 Mail 的回應**：main thread 先 prime 之後，背景 thread 執行 `get name` 回傳 `Mail`、沒有錯誤，與 #471 修正後的行為一致。

## 限制

- **高負載。** 兩輪都在 load 118–139 下量。最快一群是推估不受干擾時的依據，但沒有低負載時的重跑。
- **授權主體不同。** harness 從終端機啟動，Automation 授權屬於終端機，不是簽章的 server binary。啟動 osascript 與 Apple event 的成本應相同，但沒有用 server binary 驗證。
- **script 不同。** 只量了唯讀的 `get name`，不是觸發 script 本身。觸發 script 裡等待 Mail 列出草稿、兩次切換與 0.5 秒間隔的成本，見 #489、#488。
- **in-process 的編譯成本會隨 script 長度增加**：(e) 用的是一行 script。

## 重跑

```bash
swiftc -O -o /tmp/bench496 scripts/experiments/496-trigger-transport/bench.swift
/tmp/bench496 30 /tmp/results.json   # Mail 必須在執行，且終端機已有 Mail 的 Automation 授權
```

harness 會在送出任何 Apple event 之前確認授權。沒有授權時印出原因並以 2 結束，不會跳出授權視窗。
