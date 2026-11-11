## 1. 測試先行（RED）

- [x] 1.1 [P] 新增 `Tests/CheAppleMailMCPTests/MailLog/EventNameFilterTests.swift`，帶標記 `spec-example: mail-log-diagnostics / event-name filter validation`：逐列檢查 Event-name filter 的驗證表（合法值被接受、去重後保留順序、空陣列／21 項／空字串／1025 bytes／非陣列／非字串／未知 `imap.*` 名稱回 invalid-parameter 且 `FakeLogSource.requests` 為空）。驗證：`swift test --filter EventNameFilterTests` 在實作前失敗。
- [x] 1.2 [P] 同檔帶標記 `spec-example: mail-log-diagnostics / event-name filter matching`：逐列檢查 Event-name filter 的比對表（完全相等才保留；大小寫不同、子字串、上傳回條的原始模板、被收回模板的原文都選不到；`<template withheld>` 與過長訊息的原始模板選得到），並檢查被保留事件的 `event` 欄位等於篩選值。驗證：`swift test --filter EventNameFilterTests` 在實作前失敗。
- [x] 1.3 [P] 同檔帶標記 `spec-example: mail-log-diagnostics / event-name filter paging`：逐列檢查 Event-name filter 與翻頁的互動（`offset` 與 `next_offset` 只計算符合的事件、`scan_cap` 停止時 `next_start` 是 scan frontier、查無結果時 `events` 回顯且 `notice` 提到 event-name filter、沒給參數時 `events` 為 `null`）。驗證：`swift test --filter EventNameFilterTests` 在實作前失敗。
- [x] 1.4 加入三個 Scenario 的測試（噪音中找到上傳回條、被收回的模板不能用原文定址、打錯的已知事件名稱在讀取前被拒），並確認 `events` 不會出現在 `LogReadRequest` 裡。驗證：同上，實作前失敗。

## 2. 實作（GREEN）

- [x] 2.1 `MailLogQuery`：新增 `events` 參數（`allowedParameters`、型別與長度驗證、去重、未知 `imap.*` 拒絕，錯誤訊息列出已知事件名稱），以 `var events: [String]? = nil` 存放，既有 memberwise 呼叫不受影響。驗證：1.1 與 1.4 的驗證測試轉綠，`MailLogQueryValidationTests` 維持綠。
- [x] 2.2 `MailLogService`：抽出共用的顯示名稱函式，`shape()` 改用它（行為不變），掃描迴圈在 `contains` 的位置套用 Event-name filter；回應（含 `unavailable`）加 `events` 欄位，查無結果的 `notice` 說明篩選已套用。驗證：1.2、1.3、1.4 轉綠，既有 MailLog 測試全部維持綠。
- [x] 2.3 `MailLogTool`：schema 加 `events` 屬性，描述把「No event-name filter yet (#466)」改成 `events` 的用法（保留 `#466`），總長不超過 2048 字元。驗證：`MailLogToolTests` 的 schema 與描述長度測試維持綠。

## 3. 文件

- [x] 3.1 `README.md` 與 `README_zh-TW.md` 的 `get_mail_log_events` 列改寫為 `events` 篩選的說明（完全相等、比對顯示名稱、簡短與詳細模式都可用）。驗證：`grep -n "No event-name filter yet\|還沒有依事件名稱篩選" README.md README_zh-TW.md` 無輸出。
- [x] 3.2 `CHANGELOG.md` 的 `## [Unreleased]` 加一則條目說明新參數（#466）。驗證：內容審閱；`swift test` 全綠（含 `ManifestVersionTests`）。

## 4. Verify 第 1 輪修正

- [x] 4.1 回應改報 `event_filter_count`、不回傳篩選值：最大篩選下每種回應都在 65536 bytes 內，`size_cap` 與 cursor 不受篩選影響，呼叫端文字不出現在回應裡。驗證：`testTheLargestFilterKeepsEveryResponseWithinTheCap`、`testTheResponseCarriesNoCallerText_inEitherDetail`。
- [x] 4.2 翻頁 Example 與測試改成起始毫秒以不符合的事件開頭，能區分「先篩選再扣 offset」與相反順序。驗證：`testPagingTable`，並以把篩選移到 offset 之後的 mutation 確認轉紅。
- [x] 4.3 驗證表的拒絕列檢查 `MailError.invalidParameter` 與各列的錯誤理由；`imap.` 檢查改為依 bytes、不分 ASCII 大小寫。驗證：`testValidationTable`。
- [x] 4.4 描述、schema 與兩份 README 的續頁說明加上「同樣的 `events`」。驗證：內容審閱；`MailLogToolTests` 維持綠。
- [x] 4.5 `KnownEvents.names` 與 `name(for:)` 的對應有測試釘住。驗證：`testEveryKnownEventNameIsAcceptedByTheValidator`。

