## Why

直接寫入（`create_draft` + `CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1`）2026-10-05 的 live 計時是 3.17 秒，其中「觸發」1,667 ms 是最大的一塊，但計時檔裡它只有一個點：`inserted` 到 `trigger_sent`。這 1.67 秒裡依序有五件事：

1. 交給 osascript 子程序（含 Automation 預檢）；
2. 輪詢直到 Mail 列出新草稿；
3. 設為未讀；
4. 等 0.5 秒；
5. 設回已讀。

目前分不出哪一步花了多少時間。要找出不碰交易安全規則（`.claude/rules/direct-write-transaction-safety.md`）8 項保證的加速，得先有分解後的量測（#489）。

## What Changes

- 計時開啟時，直接寫入在 `inserted` 與 `trigger_sent` 之間多記這些點，全部 `path` 為 `direct`：
  - swift 端的 `trigger_spawn`：把上傳請求交給 osascript 傳輸層之前；
  - 觸發 script 自己記的 `trigger_script_start`、`trigger_listed`（Mail 列出新草稿）、`trigger_unread`（設為未讀之後）、`trigger_read`（設回已讀之後）。
- 沒完成的步驟不產生列，與既有規定相同。
- 計時關閉時，觸發 script 與現在逐位元組相同。
- 觸發 script 的計時點經 osascript 的 stderr 進入 `ComposeTiming` 的全域 buffer。直接寫入在觸發返回或拋錯後**立刻**取走它們、併進自己的段落，不留給之後的 GUI 段落（#483 是全域 buffer 的通盤修法）。
- 兩次已讀切換之間只多一行計時呼叫，不加 `delay`、不加控制流程。規則第 8 項的間隔不變（計時開啟時只會更長）。
- `attemptSteps` 觸發之後的程式碼被 #490 的守門測試凍結；本改動同步更新凍結副本，並讓第 8 項的守門測試同時檢查計時開／關兩種觸發 script。
- apply 後用測試帳號 live 量測 n≥10，把各子步驟的分布逐項對照規則 8 項寫成分析（可加速／不可／需實驗）。具體加速另開 issue。

## Non-Goals

- 不做任何加速，不改切換間隔（0.5 秒屬於 #488 的實驗）、等待上限與上傳確認。
- 不改 `ComposeTiming` 全域 capture buffer 的設計（#483）。
- 不改 GUI 路徑的計時點。
- 不加 Automation 預檢本身的計時點：`trigger_spawn` 到 `trigger_script_start` 這一段已包含預檢與子程序啟動，本改動不再細分。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `compose-timing`：〈Direct-write path marks〉的有序步驟清單加入觸發的子步驟，並規定 script 計時點的來源與取走時機。

## Impact

- Affected specs: `compose-timing`
- Affected code:
  - `Sources/CheAppleMailMCP/DirectDraft/DirectDraftPath.swift`：觸發 script 生成（計時開啟才加 prelude 與計時點）、`triggerDirectDraftUpload` 帶計時旗標、`attemptSteps` 記 `trigger_spawn` 並在觸發後取走 script 計時點、`DirectDraftTimer` 加併入 script 計時點的方法
  - `Tests/CheAppleMailMCPTests/DirectDraftPathTests.swift`：計時開／關的觸發 script、計時點順序、取走 buffer
  - `Tests/CheAppleMailMCPTests/DirectWriteSafetyGuardTests.swift`：更新凍結副本；第 8 項同時檢查計時開啟的觸發 script
  - `.claude/rules/direct-write-transaction-safety.md`：若守門測試清單的描述需要對應更新
