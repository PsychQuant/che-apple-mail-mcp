## 1. 計時核心：CSV 格式與 run（ComposeTiming）

- [x] 1.1 先寫失敗測試（RED）覆蓋「Timing CSV layout」與「Mismatched header is refused」：新檔第一行等於含 `path` 的 11 欄表頭、每列 11 欄且無欄位含逗號；既有檔第一行是 #464 舊表頭時 `ComposeTiming.append` 丟出錯誤且檔案位元組不變。驗證：`swift test --filter ComposeTimingTests` 新測試失敗、舊測試仍綠。
- [x] 1.2 實作 design 決策「表頭不符就拒寫」與新表頭：`csvHeader` 加 `path` 欄，`append` 對非空檔先比對第一行、不符時丟出具名錯誤。驗證：1.1 的表頭與拒寫測試轉綠。
- [x] 1.3 先寫失敗測試再實作 design 決策「每個 mark 帶自己的 path 與 outcome」：每列帶 `path`／`outcome`（由 `Segment` 承載，`Mark` 不變），`csvRows` 接受多個 segment（各有 path／outcome／config），合併後依時間排序、以整個 run 最早的 mark 為 `ms_since_start` 起點、`ms_since_prev` 跨段連續。驗證：測試以兩段假 marks（direct 段早於 gui-mailto 段）斷言排序、起點與 `path`／`outcome` 欄。
- [x] 1.4 先寫失敗測試再實作 design 決策「計時以「run」為單位，由 create_draft 持有」：`ComposeTiming` 提供 `@TaskLocal` run context（`run_id`＋累積的 segments），run 結束時一次寫出全部列；不在 run 內時維持既有「自己寫檔」。驗證：測試在 run 內加入兩段 marks 後只產生一個 `run_id`；run 外呼叫照舊寫檔。

## 2. GUI mailto 路徑接上 run

- [x] 2.1 落實「GUI mailto path marks」與「Timing is opt-in and never affects the compose call」：`MailController.recordComposeTiming` 在 run 內把 `enter`／`spawn`／`returned` 與 script marks 以 `path` `gui-mailto`、outcome `ok`／`error` 交給 run，run 外（`compose_email`）照舊寫檔並多一個 `path` 欄；寫檔失敗只在 stderr 印 `compose timing:`。驗證：`ComposeTimingTests` 斷言 run 內呼叫不直接寫檔、marks 進入 run；`ComposeScriptBuilder` 在計時關閉時輸出與現行位元組相同的既有測試維持綠。

## 3. 直接寫入路徑的計時點與 outcome 代碼

- [x] 3.1 [P] 先寫失敗測試再實作 design 決策「outcome 用固定代碼，不放原因全文」：`DirectDraftPath.Outcome` 每種結果提供 `timingCode`，值屬於 spec 的封閉清單（`created`、`created:upload_pending`、`fell_back:trigger`、`not_attempted:<19 個代碼之一>`），不符條件的代碼由 `DirectDraft.Ineligible` 的 case 名稱推導。驗證：`DirectDraftPathTests` 逐一列舉 `Ineligible` 的 9 個 case（排除 `disabled`）與 10 個閘門，斷言代碼與 spec 清單一致且不含逗號。
- [x] 3.2 落實「Direct-write path marks」：`DirectDraftPath.attempt` 在開始時記 `enter`、每個步驟成功完成時記 `eligibility`／`version_gate`／`drafts_resolved`／`writer_opened`／`inserted`／`trigger_sent`／`uploaded`／`read_ensured`，結束時必記 `returned`，未完成的步驟不記；計時關閉時不取時間。驗證：`DirectDraftPathTests` 以停用旗標與 cc 不符條件兩種情況斷言 run 內的 direct marks 分別為零列、恰好 `enter`＋`returned`（outcome `not_attempted:ccOrBcc`）。
- [x] 3.3 落實「One run per create_draft call」：`Server` 的 `create_draft` handler 在計時開啟時把整次呼叫（直接寫入嘗試＋可能的 GUI 路徑）包在同一個 run 裡，handler 結束（含丟出錯誤）時寫出。驗證：測試以 `version` 閘門失敗後走 GUI 的情境（假 controller）斷言所有列共用一個 `run_id`、direct 列在前、gui-mailto `returned` 的 `ms_since_start` 從 direct `enter` 起算。

## 4. Spec 與規則

- [x] 4.1 [P] 依 design 決策「自組 MIME 寫入本機資料庫不算 AppleScript 注入」與「直接寫入的 requirement 列封閉清單，數字與現行 code 一一對應」，核對 change 內 `message-composition` delta 的「Composing tools never inject a body via AppleScript」與「Direct-write draft path」：9 項不符條件與 `DirectDraft.Ineligible`（排除 `disabled`）逐一對應、寫入前閘門與 `DirectDraftPath.attempt` 的檢查順序一致、fallback 訊息字串與 `DirectDraftPath.fallbackNote` 相同。驗證：逐條比對後 `spectra validate admit-direct-write-draft-source` 通過；`NoBodyInjectionGuardTests` 維持綠。
- [x] 4.2 [P] 三份 compose 規則（`.claude/rules/compose-wrapper-free.md`、全域鏡像 `che-claude-config/rules/common-mail-compose.md`、`plugin/rules/compose-wrapper-free.md`）的〈現況〉表各加一列（全域鏡像沒有表格，改在對應句子後補一句）：「`create_draft`（opt-in 直接寫入，#472）：自組 MIME 寫入本機資料庫，不經 Mail 編輯器、不經 AppleScript 內文屬性」，六類失敗對照表不變。驗證：三份 `diff` 只差這一列（與各自既有差異），內容彼此一致。
- [x] 4.3 [P] `CHANGELOG.md` 的 `[Unreleased]` 記錄：計時 CSV 新增 `path` 欄並涵蓋直接寫入路徑、舊表頭檔會被拒寫（需換新檔）、spec 承認 opt-in 直接寫入。驗證：內容審閱，與 1.2、3.2、4.1 的行為一致。

## 5. 驗證

- [x] 5.1 全套測試綠燈。驗證：`swift test` 0 failures（依 repo 慣例先取得使用者同意再跑全套）。
- [x] 5.2 Live 驗證三條路徑的 CSV：以新的計時檔、開啟直接寫入，對測試帳號各跑一次（a）符合條件的草稿（只有 `direct` 列，outcome `created`）、（b）帶 cc 的草稿（`direct` 的 `enter`＋`returned` 接 `gui-mailto` 列、同一 `run_id`）、（c）關閉直接寫入的草稿（只有 `gui-mailto` 列）；另以舊表頭檔確認拒寫與 stderr 訊息。探針以 `[idd-475-probe]` 為主旨、`.invalid` 收件人，結束後以 id-delta 清理。驗證：把三段 CSV 摘錄（去除帳號）貼到 #475。

## 6. Verify R1 修正（Codex lens）

- [x] 6.1 落實 design 決策「寫入以鎖串行化，欄位也去掉雙引號（verify R1）」的寫入部分：`ComposeTiming.append` 以 process 內鎖＋`flock`＋`O_APPEND` 串行化，表頭檢查與寫入都在鎖內；`Timing CSV layout` 的並發條款成立。驗證：`testConcurrentAppendsKeepEveryRowAndOneHeader`（16 個並發 writer）修正前 RED、修正後連跑 3 次綠。
- [x] 6.2 `csvField` 把雙引號換成單引號，`Timing CSV layout` 的「不含逗號或雙引號」成立。驗證：`testNoFieldContainsADoubleQuote` 修正前 RED、修正後綠。

## 7. Verify R2 修正

- [x] 7.1 B1／B3：`message-composition` delta 以 MODIFIED 改「Plain mode preserves existing behavior」（內文來源指向兩種來源，直接寫入對內文 HTML 跳脫）與「Ineligible composing calls fail without side effects」（六類屬 GUI 路徑，直接寫入建立草稿時第 3 類不適用）；`create_draft` 的 tool description 同步。驗證：`spectra validate` 通過；`ToolCountCensusGuardTests` 以重產的 manifest 通過。
- [x] 7.2 B2：三份 compose 規則的〈能力損失〉段寫明 opt-in 直接寫入在封閉適用條件內不開視窗；退回時機補上「觸發上傳失敗並還原」。驗證：三份內容審閱一致。
- [x] 7.3 I1：`append` 對尾端缺換行的檔先補換行。驗證：`testHeaderWithoutTrailingNewlineIsNotGluedToTheFirstRow`、`testATruncatedLastRowDoesNotSwallowTheNextRow`；mutation（拿掉補換行）2 個測試轉紅。
- [x] 7.4 I2：`read_ensured` 只在觀察到已讀時記；讀不到時回提示。驗證：`testReadCheckOnlyConfirmsAnObservedReadFlag`。
- [x] 7.5 I3：`flock` 改為不阻塞、約 1 秒的有限重試，逾時放棄該批列。驗證：`testABusyLockGivesUpInsteadOfBlocking`；mutation（改回阻塞）測試轉紅。
- [x] 7.6 I4／I5：同一時間戳的列保持輸入順序；寫不進的路徑丟出具名錯誤、run 仍回傳原結果。驗證：`testMarksWithEqualTimestampsKeepTheirInputOrder`、`testAnUnwritablePathThrowsANamedErrorAndARunStillReturns`。
- [x] 7.7 I6：proposal（9 類）、design（Segment 載體、測試範圍、並發 marks 風險）、tasks、compose-timing spec（`drafts_resolved`、`read_ensured`、`created`、`not_attempted`、`update_draft`）措辭對齊。驗證：`spectra validate` 通過。
