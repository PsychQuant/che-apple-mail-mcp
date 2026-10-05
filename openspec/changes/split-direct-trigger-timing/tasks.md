## 1. 觸發 script 的計時點

- [x] 1.1 （Requirement: Direct-write path marks；design D1、D2：計時旗標怎麼傳）`buildDirectDraftTriggerScript(rowId:timing:)` 在 `timing: true` 時以 `ComposeTiming.prelude` 開頭，並依 design D1 的位置加入 `trigger_script_start`、`trigger_listed`、`trigger_unread`、`trigger_read` 四個計時點；`timing: false` 時輸出與現在逐位元組相同。驗證：`DirectDraftPathTests` 新測試比對 `timing: false` 的輸出與修改前的字串完全相同；`timing: true` 的輸出含四個計時點且順序正確；兩次 `set read status` 之間只有 `trigger_unread` 一行計時呼叫與 `delay 0.5`
- [x] 1.2 #490 第 8 項守門測試同時檢查計時開啟的觸發 script：`toggleGap(in: buildDirectDraftTriggerScript(rowId:timing: true))` 為 `.seconds` 且 ≥ 0.5。驗證：`DirectWriteSafetyGuardTests` 新測試通過；把計時版的 `delay 0.5` 改成 0.3 時轉紅（手動 mutation，不 commit）

## 2. 取走 script 計時點

- [x] 2.1 [P] `ComposeTiming.takeCapturedMarks(where:)` 在同一個鎖內只移出符合條件的點，其他點留在 buffer。驗證：`ComposeTiming` 相關測試新增案例，buffer 裡同時有 `trigger_x` 與 `script_start` 時，取 `trigger_` 前綴後只剩 `script_start`
- [x] 2.2 （design D3：在哪裡、何時取走 script 計時點）`DirectDraftTimer` 新增 `isRecording`（有 run 時為 true）與 `absorbScriptMarks()`：取出 `trigger_` 前綴的 script 點併入本段落；沒有 run 時不取、不併。驗證：`DirectDraftPathTests` 新測試在有 run 與沒有 run 兩種情況下檢查 buffer 與段落內容

## 3. 接上直接寫入的觸發

- [x] 3.1 （Requirement: Direct-write path marks；design D2：計時旗標怎麼傳、D3：在哪裡、何時取走 script 計時點、D4）`triggerDirectDraftUpload(rowId:timing:)` 用 `buildDirectDraftTriggerScript(rowId:timing:)` 產生 script；`attemptSteps` 在 `let triggered = Date()` 之後記 `timer.mark("trigger_spawn")`，以 `timing: timer.isRecording` 呼叫觸發，並在觸發返回後、`trigger_sent` 之前，以及 `catch` 的第一行，各呼叫一次 `timer.absorbScriptMarks()`。其他行不變（等待、補設已讀、還原與回報都不動）。驗證：全套測試通過；`git diff` 只在觸發前後多出上述行
- [x] 3.2 更新 `DirectWriteSafetyGuardTests` 的凍結副本（`frozenPostTrigger`）與 `pinnedNameLines`（若呼叫行改變），並逐行對照規則第 2、3、6、7 項確認只新增計時呼叫。驗證：`swift test --filter DirectWriteSafetyGuardTests` 全部通過，所有反例仍會轉紅
- [x] 3.3 若 `.claude/rules/direct-write-transaction-safety.md` 的守門測試清單或「另有測試」清單因本改動而不準，同步修正（例如 `triggerDirectDraftUpload` 的測試狀態）。驗證：內容審查，清單中每個名稱都能用 `grep` 在 `Tests/` 找到或確認沒有

## 4. 全套測試與 live 量測

- [x] 4.1 全套測試兩個 bundle（`CheAppleMailMCPTests`、`MailSQLiteTests`）0 failure。驗證：`swift test` 輸出
- [x] 4.2 建簽章 binary，用測試帳號在 opt-in 直接寫入加計時開啟的情況下建立至少 10 封合格的純文字草稿；另以計時關閉跑至少 5 封作對照。結束後用 id-delta 清除測試草稿（本機與伺服器），不使用 `whose content contains`。驗證：計時 CSV 每次都有完整的 `trigger_*` 子步驟；清除後 Envelope Index 查不到測試草稿。結果：12/12 有完整子步驟；草稿匣與全部郵件已清空，垃圾桶留 17 封合成副本（AppleScript 無法永久刪除垃圾桶郵件，由 Gmail 30 天自動清除，同 #463）
- [x] 4.3 把各子步驟的中位數與範圍、以及計時開／關的總觸發時間差，逐項對照規則 8 項寫成分析表（可加速／不可／需實驗），貼到 #489。驗證：內容審查，每個子步驟都有對應的規則項判斷
