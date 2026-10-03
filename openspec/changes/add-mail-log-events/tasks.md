## 1. 基礎：fixture 與子行程邊界

- [x] 1.1 [P] 建立合成 ndjson fixtures 與 ndjson 解析器：fixtures 重建 #463 的事件鏈（存檔、建立 action、處理 action、通知引擎、`APPENDUID` 回條）加上雜訊、整行都是 `%{public}@` 的事件、`<private>` 數字參數，以及在 `%@` 內注入的 email、UUID、角括號 Message-ID；解析器把每行轉成事件，時間轉成帶偏移的 ISO 8601（毫秒精度），略過計數尾行（`{"count":…,"finished":1}`）與無法解析的行並累計 `skipped_lines`，對應 Honest status and coverage reporting 的 Unparseable line。驗證：`MailLogFixtureHygieneTests` 斷言 fixture 內所有 email 形狀字串都在 `.invalid` 網域、不含 `/Users/`；`NdjsonParserTests` 對含一行壞 JSON 的輸入回傳其餘事件且 `skipped_lines` 為 1（先寫測試並確認 RED，再實作）。檔案位置：`Tests/CheAppleMailMCPTests/Fixtures/MailLog/`、`Sources/CheAppleMailMCP/MailLog/NdjsonParser.swift`
- [x] 1.2 [P] 定義 `LogEventSource` 介面（讓測試可注入假資料來源，也讓日後切換讀取實作只動一處）與以 `Process` 實作的 `LogShowRunner`，落實 Bounded subprocess execution 與以 log show 子行程讀取 unified log：使用絕對路徑 `/usr/bin/log` 與參數陣列、不經 shell；逐行串流讀取；讀取上限 64 MiB（超過停止並回報 `scan_cap`）；deadline 30 秒；任何原因停止讀取時都終止並回收子行程；predicate 只由固定文字與通過 `^[A-Za-z0-9_.-]{1,64}$` 的 category token 組成。驗證：`LogShowRunnerTests` 以 `/bin/sh -c` 造一個會無限輸出的假子行程，處理函式要求停止後 5 秒內子行程已結束；以非零結束碼的假子行程驗證 `nonzero_exit` 與 stderr 尾端最多 300 字元；斷言傳給子行程的參數不含任何呼叫端文字（Caller text never reaches the predicate、Scan cap、Spawn failure 三個 scenario）。檔案：`Sources/CheAppleMailMCP/MailLog/LogShowRunner.swift`

## 2. 事件整形（每項先寫測試）

- [x] 2.1 [P] 實作簡短模式以 formatString 作為事件名稱的模板抽取器，落實 Brief output excludes runtime-derived text：把 `formatString` 切成字面／整數佔位符／其他佔位符的序列，在萬用段處分段——開頭段從訊息起點比、尾段必須剛好吃到訊息結尾且只有一個起點做得到、帶整數的中段必須唯一；整數佔位符吃 `-?\d+` 或 `<private>`（對應 `null`），整數緊貼萬用段或任一條件不成立就回 `unstructured` 與空 `args`（第一版的錨定正規表示式在 verify round 1 換成逐段比對，round 2 改成分段錨定，見 6.2）。驗證：`TemplateExtractorTests` 涵蓋 spec 的 argument extraction 範例表與各 scenario。檔案：`Sources/CheAppleMailMCP/MailLog/TemplateExtractor.swift`
- [x] 2.2 [P] 實作白名單只收 APPENDUID 回條的比對器，落實 Known unstructured event recognition：category 為 `IMAPConnection`、`formatString` 沒有字面文字，且在這一行自己的 `Read: `（訊息開頭，或緊接連線標頭 `[伺服器] <…]> ` 之後）接著不以 `*` 開頭的 tag、`OK ` 與 `[APPENDUID (<數字>, <數字>…)]`（Mail 實際記下的形狀）時，簡短輸出 `kind: "known"`、`event: "imap.append_uid_received"`、空 `args`，不帶任何訊息內容；名單封閉、不做相似類推。驗證：`KnownEventsTests` 全部以真實形狀撰寫（見 5.2、6.3）。檔案：`Sources/CheAppleMailMCP/MailLog/KnownEvents.swift`
- [x] 2.3 [P] 實作帳號以回應內代號區分，落實 Account aliasing within a response：只有以 `[帳號 - 信箱]` 開頭、而且模板把這個括號放在開頭（模板以萬用段開頭且有字面，或模板本身以 `[%@ - ` 開頭）的訊息才取帳號鍵（`[` 到第一個 ` - `），依首次出現順序指派 `A`、`B`、`C`，帳號鍵從不輸出，其他情況 `account: null`，並計算 `accounts_seen`。驗證：`AccountAliasTests`（見 5.5、6.4）。檔案：`Sources/CheAppleMailMCP/MailLog/AccountAlias.swift`、`Sources/CheAppleMailMCP/MailLog/MailLogService.swift`
- [x] 2.4 [P] 實作詳細模式的敏感標示與選用遮蔽中的遮蔽函式，落實 Optional identifier redaction in detailed output：email 形狀、UUID 形狀、角括號 Message-ID 形狀依首次出現順序換成 `<email-N>`、`<uuid-N>`、`<message-id-N>`，同一字串在單一回應內得到同一個 N；預設關閉；啟用時回應帶 `redaction` 並寫明盡力而為、不是隱私保證。驗證：`RedactionTests` 的 Redaction applied（同一 email 出現兩次得到同一代號）與 Redaction off by default 兩個 scenario，並斷言帳號顯示名稱不在遮蔽範圍。檔案：`Sources/CheAppleMailMCP/MailLog/Redaction.swift`

## 3. 工具本體

- [x] 3.1 實作 Query window and parameter validation，含時間參數必須帶時區偏移與 contains 只在詳細模式提供：窗口三選一（`last_minutes` 1 至 60、`since` 加選用 `until`、`around` 加選用 `radius_seconds` 1 至 1800）、未給窗口時預設 10 分鐘、跨度上限 60 分鐘、時間字串必須帶明確偏移、`contains` 與 `redact_identifiers` 僅詳細模式、`categories` 與 `limit` 範圍檢查；任何違規回 invalid-parameter 錯誤且不 spawn 子行程；本機時區轉換後才傳給 `log show`。驗證：`MailLogQueryValidationTests` 涵蓋 spec 的 validation boundaries 範例表全部列，以及 Naive timestamp rejected、Substring filter is not available in brief detail、Two window forms combined 三個 scenario，並用假 `LogEventSource` 斷言呼叫次數為 0。檔案：`Sources/CheAppleMailMCP/MailLog/MailLogQuery.swift`
- [x] 3.2 實作 Result limits, truncation, and paging 與窗口、筆數上限與由早到晚的分頁：事件由早到晚、讀到 `limit + 1` 筆相符事件就停止（讀到倒序事件後不再提前停止）、回傳最早的 `limit` 筆、`truncated`、`stopped_by`、游標 `next_start` 加 `next_offset`（續查時以 `since` 加 `offset` 傳回）；序列化後超過 65,536 位元組時從尾端丟棄並標 `size_cap`。驗證：`ResultPagingTests`（見 5.1、6.1）。檔案：`Sources/CheAppleMailMCP/MailLog/MailLogService.swift`
- [x] 3.3 在同一服務中實作 Honest status and coverage reporting 與誠實的未知與涵蓋範圍：`status` 三態、`window`、`coverage`、`stopped_by`、`unavailable` 的 `reason`（`spawn_failed`、`nonzero_exit`、`unrecognized_output`、`deadline_exceeded`、`scan_cap_exceeded`）、提早停止後已讀到超過游標的窗口內事件則回傳並標 `deadline`／`scan_cap`；不存在任何斷言「沒發生」的欄位。驗證：`HonestStatusTests` 與 `ResultPagingTests` 的停止情境（見 5.3、6.1）。檔案：`Sources/CheAppleMailMCP/MailLog/MailLogService.swift`
- [x] 3.4 實作 Detailed output exposes raw log lines with a sensitivity notice：詳細事件在簡短欄位之外加 `message`、`process`（映像檔 base name）、`thread`，回應帶 `contains_sensitive: true` 與禁止貼進公開 issue 的 `notice`；`contains` 在行程內比對。驗證：`DetailedOutputTests` 的 Detailed fields and notice scenario，以及 `contains` 含引號與括號時假子行程的參數陣列不含該值。檔案：`Sources/CheAppleMailMCP/MailLog/MailLogService.swift`
- [x] 3.5 在 `Server.swift` 註冊 Read-only Mail log query tool，落實單一工具以 detail 參數切換簡短與詳細：工具 `get_mail_log_events`、input schema、處理函式經可注入的 `LogEventSource` 取資料、description 寫明詳細模式含帳號識別資訊不可貼進公開 issue、已驗證版本（Mail 16.0／macOS 27.2）與未驗證情境（`.mcpb` 啟動、非 admin 使用者）。驗證：`MailLogToolTests` 斷言工具存在、description 含上述三項、input schema 中 `contains` 與 `redact_identifiers` 的說明標明僅詳細模式可用；Default query 與 Tool never touches Mail state 兩個 scenario（斷言沒有 AppleScript 被執行、沒有以寫入模式開啟 Mail 資料庫）。檔案：`Sources/CheAppleMailMCP/Server.swift`

## 4. 守門測試、文件與驗證

- [x] 4.1 [P] 加簡短輸出的端到端守門測試：把 1.1 的注入識別資訊 fixture 走完整管線（解析、模板抽取、帳號代號、輸出序列化），斷言序列化結果不含任何注入的 email、UUID、Message-ID，也不符合三種形狀的正規表示式（Identifiers in message arguments never appear 的完整版）；另斷言簡短模式帶 `contains` 被拒絕，防止用子字串比對逐步逼問出識別資訊。驗證：`BriefOutputNoIdentifierGuardTests` 在 `swift test` 全綠，且把守門條件暫時移除時此測試變紅（紅綠循環）。檔案：`Tests/CheAppleMailMCPTests/MailLog/BriefOutputNoIdentifierGuardTests.swift`
- [x] 4.2 [P] 同步文件與工具數：`README.md`、`README_zh-TW.md`、`mcpb/manifest.json`、`server.json` 的工具數宣稱、分節小計與工具表加入 `get_mail_log_events`（`plugin/README.md` 沒有工具數宣稱，其版本歷史列在發版時才更新），`CHANGELOG.md` 新增一節說明新工具、簡短與詳細的差異、已驗證與未驗證的環境。驗證：`swift test --filter ToolCountCensusGuardTests` 通過。
- [x] 4.3 量測 `log show` 與 `OSLogStore` 兩條讀取路徑（以 log show 子行程讀取 unified log 這項決定可逆，本量測是其驗證）：對同一個 60 分鐘窗口各量尖峰記憶體、提前取消的行為、與筆數差異來源；結果以一則帶日期的備註追加到本 change 的 `design.md` Decisions，並貼到 #465。驗證：備註中有兩條路徑的實測數字與結論；若 `OSLogStore` 的取消沒有問題且明顯更省，開 follow-up issue 切換實作（因為有 `LogEventSource` 介面，切換只動實作）。
  - 結果（2026-10-02）：不切換。`OSLogStore` 取消沒有問題、筆數差異是假象（固定窗口內兩者一致），但在伺服器行程內每次呼叫約 +230 MB 且未歸還，`log show` 子行程則在結束時歸還；詳見 design.md 該 Decision。
- [x] 4.4 有人值守的 live 驗證與延後項目追蹤：用簽章後的 binary 在本機呼叫 `get_mail_log_events`，重建 #463 的真實窗口（草稿存檔到佇列到通知引擎到 `APPENDUID`），並確認簡短輸出沒有帳號或主旨；`.mcpb` 啟動與非 admin 使用者兩個情境依 `.claude/rules/deferred-live-verification.md` 二擇一：實際跑掉並把指令與觀測值寫進 closing comment，或貼 `blocked-on-setup` label 讓 #465（或專屬追蹤 issue）保持 OPEN 並確認 3.5 的 description 已有但書。驗證：closing comment 內有指令與觀測值，或 issue 上有該 label。

## 5. Verify round 1 修正（#465 comment 5948663621 的六個阻擋性群組與 in-scope fix）

- [x] 5.1 Result limits, truncation, and paging 的游標改為「第一筆未回傳的事件」、一頁不切開同一時間戳的事件群、`scan_cap`／`deadline` 時游標為掃描前緣、`size_cap` 時為第一筆放不下的事件；回應上限 65,536 位元組（finding #1／#9／#16／#49）。驗證：`ResultPagingTests` 的 `testLimitOne_pagesThroughDistinctTimestampsWithoutStalling`、`testPagingThroughBursts_neverLosesOrRepeatsAnEvent`（limit 1、2、7、10、43、48、100 逐一翻頁，與不分頁結果逐筆相等）、`testScanCapReportsTheScanFrontierSoTheCallerCanContinue`、`testTheByteCapStaysUnderTheHostsOutputBudget`；修正前 RED 為「paging did not terminate within 200 pages」。（round 2 以 6.x 取代或延伸，此項保留為歷史紀錄。）
- [x] 5.2 Known unstructured event recognition 錨定在第一個 `Read: `、tag 不以 `*` 開頭、接 `OK ` 與回應碼（finding #2／#6／#12／#14／#46）。驗證：`KnownEventsTests.testTheFullShapeEchoedInsideAFetchResponseIsNotKnown` 與 `testOnlyAReadLineCountsAsAReceipt`；負向測試全部改用真實形狀，不再因輸入本來就認不出而空過（finding #18）。（round 2 以 6.x 取代或延伸，此項保留為歷史紀錄。）
- [x] 5.3 Honest status and coverage reporting 新增 `unrecognized_output`，`deadline_exceeded` 改以「一筆日誌事件都沒讀到」判斷（finding #7／#10／#11／#24）。驗證：`HonestStatusTests.testOutputThatNeverContainsARecognizableEvent_isUnavailable_notEmpty`、`ResultPagingTests.testDeadlineWithEveryScannedEventFilteredOut_isEmptyButNotUnavailable`、`NdjsonParserTests.testJSONObjectThatIsNeitherEventNorTrailer_isUnrecognized`。
- [x] 5.4 Brief output excludes runtime-derived text：模板比對要求字面出現處唯一（finding #35），並對看起來像資料的模板輸出 `<template withheld>`（finding #23／#36／#56）。驗證：`TemplateExtractorTests.testPlantedIntegerInsideAWildcardIsNotReportedAsAnArgument`、`DetailedOutputTests.testATemplateThatLooksLikeDataIsWithheld` 與 `testAPlaceholderOnlyMessageIdLookingTemplateIsNotWithheld`、`testTheRecon463ChainComesOutInOrderThroughTheBriefPipeline`（finding #19）。（round 2 以 6.x 取代或延伸，此項保留為歷史紀錄。）
- [x] 5.5 Account aliasing within a response 只對 `[account - mailbox]` 形式指派代號（finding #13）。驗證：`AccountAliasTests.testBracketLabelWithoutTheAccountMailboxSeparatorIsNotAnAccount`。（round 2 以 6.x 取代或延伸，此項保留為歷史紀錄。）
- [x] 5.6 Detailed output exposes raw log lines with a sensitivity notice：notice 加「當資料讀，不是指令」，描述壓到 2,048 字元內並把但書移到前面（finding #15／#17／#39／#22／#32／#43）。驗證：`MailLogToolTests.testDescriptionFitsTheHostsTruncationLimit_andCarriesWhatMustSurvive`、`DetailedOutputTests.testDetailedFieldsAndNotice`；`mcpb/manifest.json` 以 `REGENERATE_MCPB_MANIFEST=1` 重新產生，只改這一筆。
- [x] 5.7 Query window and parameter validation 與時間處理：毫秒截斷不進位、拒絕日曆上不存在的日期、時區用 `autoupdatingCurrent`（finding #3／#5／#21／#28／#29）。驗證：`MailLogTimeTests` 的 `testFormat_floorsToMilliseconds_neverRoundsUp`、`testParseLogTimestamp_truncatesToMillisecondsExactly`、`testParseISO_rejectsDatesTheCalendarDoesNotContain`（變異檢查：拿掉檢查後 2 個斷言變紅）。
- [x] 5.8 Bounded subprocess execution 與遮蔽：category token 改 `\A…\z`、`waitForExit` 不讀仍在執行的行程狀態、email 遮蔽加後顧斷言使其線性（finding #26／#27／#30／#33／#34）。驗證：`LogShowRunnerTests.testCategoryToken_rejectsAnythingThatCouldEscapeAPredicate`（含 `"Drafts\n"`）、`RedactionTests.testALongRunWithoutAnAtSignStaysLinear`（修正前 4.99 秒）。
- [x] 5.9 文件：spec、design、CHANGELOG、README、`.claude/rules/r-must-direct-db.md` 的例外段、`mcpb/PRIVACY.md` 對齊新行為（finding #8／#20／#31／#40／#44／#51／#57）。驗證：`spectra validate add-mail-log-events` 通過，`swift test` 全綠。

## 6. Verify round 2 修正（findings 1–25；分級見 #465 的 Round 2 報告）

- [x] 6.1 Result limits, truncation, and paging 改成位置游標 `(next_start, next_offset)` 與輸入 `offset`：`limit`／`size_cap` 後為最後回傳事件之後，`scan_cap`／`deadline` 後為掃描前緣；同毫秒群組大於 64 KiB 也逐頁取完；讀到倒序事件就停用提前停止並在 `notice` 說明；沒有超過游標的進度時回 `unavailable`（`deadline_exceeded`／`scan_cap_exceeded`）；`since` 可等於 `until`；計算出的窗口截到毫秒（finding 1／2／4／5／11／12／14／19／22／23／27）。驗證：`ResultPagingTests.testABurstLargerThanTheSizeCap_pagesThroughExactlyOnce`、`testPagingThroughBursts_returnsEveryEventExactlyOnce`、`testAnInversionAfterThePageFillsIsStillPickedUpByTheNextPage`、`testScanCapAfterReturningTheFrontierEvent_continuesWithoutRepeating`、`testAStopThatMakesNoProgressPastTheCursor_isUnavailable_notAStall`、`MailLogQueryValidationTests.testOffset`／`testSinceEqualToUntil_isAZeroWidthClosedWindow`／`testComputedWindowsAreTruncatedToTheMillisecond`；變異檢查：size-cap 游標改回「第一筆放不下的事件」時分頁測試 203 個斷言變紅。
- [x] 6.2 Brief output 的模板比對改成分段錨定（尾段從訊息結尾定位、只要求帶整數的中段唯一、整數緊貼萬用段不報）；備援的 email 形狀與遮蔽共用同一個線性 pattern，超過 1,024 字元的模板直接擋下（finding 3／6／17／20）。驗證：`TemplateExtractorTests` 的 `testTheTailAfterTheLastWildcardIsMatchedFromTheEnd`、`testANumberPlantedInTheLastWildcardCannotReachTheTail`、`testAnIntegerDirectlyBesideAWildcardHasNoBoundary`、`testTheDataShapeBackstopIsBoundedAndSharesTheRedactionPattern`；真實日誌 8 小時 382,806 筆：模板帶整數的事件抽到 112,028 筆（舊規則 104,919），兩規則都抽到的 250,138 筆整數 0 筆不同。
- [x] 6.3 Known unstructured event recognition 錨定在這一行自己的 `Read: `（訊息開頭或連線標頭之後，標頭結束於第一個 `]> `）（finding 7／13）。驗證：`KnownEventsTests.testAReadPlantedInsideAWriteLineIsNotAReceipt`、`testAMailboxNameWithAngleBracketsStillFindsTheHeader`；真實日誌 2/2 回條認得。
- [x] 6.4 Account aliasing 只對模板把 `[帳號 - 信箱]` 放在開頭的兩種形狀指派（finding 18）；連線層的行沒有代號寫進 spec、design 與 description（finding 25）。驗證：`AccountAliasTests.testOnlyAWildcardLedTemplateWithLiteralTextGetsALetter`；真實日誌新舊規則同為 122,853 筆、8 個帳號。
- [x] 6.5 Optional identifier redaction：開啟遮蔽時 `contains` 比對遮蔽後的文字（finding 24）；毫秒 floor 的容差改為 0.5 µs（finding 16）。驗證：`DetailedOutputTests.testWithRedactionOn_containsSeesOnlyTheMaskedText`、`MailLogTimeTests.testFormat_floorsToMilliseconds_neverRoundsUp`（兩項皆做變異檢查：改回原行為即變紅）。
- [x] 6.6 文件：spec、design、tasks、CHANGELOG、README、工具描述與 schema 對齊（finding 9／10／11／13／17／21／25）；`mcpb/manifest.json` 重新產生。驗證：`spectra validate add-mail-log-events` 通過、`swift test` 全綠、`ToolCountCensusGuardTests` 通過。

## 7. Verify round 3 修正（分級見 #465 的 Round 3 報告）

- [x] 7.1 每個事件的文字上限一律以 UTF-8 位元組計：`message` 8,192、模板 1,024、category 128；遮蔽在截斷前、於前 16,384 位元組內做；`contains` 只比對回傳的文字；簡短模式不解析超過 64 KiB 的訊息（finding 1／13／15／17／18）。驗證：`ResultPagingTests.testOneEventCanNeverExceedTheCap_bytesNotCharacters`（修正前 205 KB）、`DetailedOutputTests.testContainsSeesOnlyTheReturnedTextAndABoundaryAddressStaysMasked`、`testAnOversizedMessageIsNotParsedInBrief`。
- [x] 7.2 runner 的 `--end` 一律推到下一個整秒；強制停止時等 stderr 讀取執行緒結束才關閉 handle（finding 3／5／11／14）。驗證：`LogShowRunnerTests.testArguments_endIsAlwaysPastTheWindowsLastSecond`；live：`since == until` 落在有事件的整秒時讀得到。
- [x] 7.3 回條：tag 為數字與點（最多 16 字元），回條必須是整塊（finding 4／6／10）。驗證：`KnownEventsTests.testAContinuationChunkThatStartsWithForgedTextIsNotAReceipt`；log store 40 小時 27 筆真實回條 27/27 認得。
- [x] 7.4 讀取中出現倒序時，提早停止的游標不跳到掃描前緣；「每筆恰好一次」改寫成以讀取順序等於時間順序為前提（finding 2／8／12）。驗證：`ResultPagingTests.testAfterAnInversionTheEarlyStopCursorDoesNotJumpToTheFrontier`。
- [x] 7.5 文件：spec 補上驗證規則（categories 1–20、`contains` 1–200、`until`／`radius_seconds` 的相依、整數值的 JSON 數字）、游標以毫秒為單位的進度定義、回條歸屬的實測更正（activity id 27 筆中 19 筆為 0）、design 與 proposal 的「結構上不可能」加上前提（finding 7／9／16／19／20／23）。驗證：`spectra validate add-mail-log-events` 通過、`swift test` 全綠。

## 8. Verify round 4 修正（分級見 #465 的 Round 4 報告）

- [x] 8.1 詳細模式的訊息改成在原文上截斷、退回最後一個空白（最多 1,024 位元組），再只對回傳的那段遮蔽；`contains` 比對同一段（finding 1–6、9、12、17）。驗證：`DetailedOutputTests.testTheFilterAndTheReturnedTextCoverTheSameSpan`（修正前 10 個邊界位置失敗）、`testACutNeverLeavesAnUnmaskedFragment`（修正前 16,384 邊界 7 個位置回傳半個地址）、`testMaskNumbersCountOnlyTheReturnedSpan`、`testVeryLongMessageIsTruncatedAndFlagged`。（已被 9.1／9.3 取代，保留為歷史紀錄。）
- [x] 8.2 單一事件的上限由構造保證：subsystem、category、process 超過 128 位元組隱藏；單一事件仍超過上限時訊息縮到 1,024、再到 0（finding 7／13／18）。驗證：`DetailedOutputTests.testTheWorstCaseAcrossEveryFieldStillFitsTheCap`、`testBriefWithholdsAnOverlongCategoryAndTemplate`。
- [x] 8.3 簡短模式的解析上限 40 KiB、佔位符上限 64、帳號括號須在前 1 KiB 內（finding 14／19）。驗證：`DetailedOutputTests.testBriefParsingIsBoundedInEveryDimension`。（已被 9.1／9.3 取代，保留為歷史紀錄。）
- [x] 8.4 stderr 描述符由讀取執行緒在最後一次讀取後自己關閉（finding 11／15／21）；以讀碼為據，競態無可靠測試。
- [x] 8.5 補 round 3 情境的服務層測試：整秒的一毫秒窗口、倒序且一筆未回傳時仍以前緣為游標（finding 8）。驗證：`ResultPagingTests.testSinceEqualToUntilOnAWholeSecondReturnsThatMillisecond`、`testAfterAnInversionWithNothingReturnedTheFrontierIsStillTheCursor`。
- [x] 8.6 可重跑的 live 驗證：`scripts/mail-log-live-check.py`（含回條普查：log store 內每一筆回條以其毫秒查詢都須為 `known`）；spec 的 tag 措辭改為「以單一點分隔的數字」，並記下帶尾巴的回條是已知限制（finding 10／20）。

## 9. Verify round 5 修正（分級見 #465 的 Round 5 報告）

- [x] 9.1 截斷改成退到最後一個安全切點（空白之後、`<` 之前、`>` 之後），沒有切點就不回傳；不再有 1,024 位元組的退讓上限（finding 1／5／8／16）。驗證：`DetailedOutputTests.testNoFragmentEvenInsideALongRunWithoutWhitespace`（修正前三個案例回傳片段）、`testVeryLongMessageIsTruncatedAndFlagged`。
- [x] 9.2 移除縮減訊息的後備路徑（走不到，且會讓 `contains` 看見不回傳的文字）；以測試證明所有欄位同時最壞時單一事件仍在上限內（finding 4／12／13／15／17／20／21）。驗證：`DetailedOutputTests.testTheWorstCaseForEveryFieldAtOnceFitsWithoutShortening`（brief、detailed、detailed＋遮蔽）。
- [x] 9.3 解析上限調回 64 KiB、兩種模式皆適用（finding 11／23）。驗證：`DetailedOutputTests.testBriefParsingIsBoundedInEveryDimension`。
- [x] 9.4 live 檢查腳本：窗口改為從最近 24 小時的日誌自動找；size-cap 分頁依截斷規則比對；分頁以原始 `log show` 為對照；回條普查改成每毫秒比對筆數，並把不符合回條形狀的 APPENDUID 行分開計（finding 2／3／6／7／18）。驗證：`scripts/mail-log-live-check.py` 對真實日誌執行。
- [x] 9.5 文件：stderr 讀取執行緒的已知限制、`contains` 遮罩不帶編號的措辭（finding 14／19／22）。

## 10. Verify round 6 修正（分級見 #465 的 Round 6 報告）

- [x] 10.1 比對器的工作有界：整數最多 20 位、尾段只在其最大可能長度內找、帶整數的中段最多 1,024 個候選位置（finding 4／6／14；修正前 debug build 量到 86 秒）。驗證：`TemplateExtractorTests.testTheMatchersWorkIsBoundedOnAdversarialInput`、`testAnIntegerLongerThanTwentyDigitsIsNotAnArgument`、`testIntegerOverflowDegradesToNilNotCrash`。
- [x] 10.2 截斷：cap 之後原文的下一個字元也算切點判斷；空白只用 `CharacterSet` 與 ICU `\s` 的交集（U+200B 除外；VT、NEL 實測兩邊都算）（finding 1／7／12／13／17）。驗證：`DetailedOutputTests.testEachSafeCutPointIsNeeded`（拿掉 `>` 規則、`<` 規則、cap 後字元的判斷，三者各自讓測試變紅）、強化後的 `testNoFragmentEvenInsideALongRunWithoutWhitespace`。
- [x] 10.3 解析上限在兩種模式的精確邊界（65,536／65,537）、單一事件上界 61,440 位元組寫進 spec 並由測試釘住（finding 8／9）。驗證：`DetailedOutputTests.testTheParseBoundHoldsInEitherDetailAtItsEdge`、`testTheWorstCaseForEveryFieldAtOnceFitsWithoutShortening`。
- [x] 10.4 live 腳本：3b／3c 兩側用相同的毫秒邊界；3c 以獨立寫出的截斷規則要求完全相等；3a 對已知事件與隱藏模板只比時間；普查在沒有 APPENDUID 時回 SKIP；移除死碼（finding 2／3／5／11／19／30）。
- [x] 10.5 文件：stderr 已知限制移到 design 並改成觀察範圍內的陳述、#467 補註納入；CHANGELOG 補上長 token 回空字串與整數位數上限；tasks 8.1／8.3 標為已取代（finding 10／15／16／18／20）。

## 11. Verify round 7（PASS：無阻擋性問題）後的 in-scope 修正——只動測試、文件與腳本，產品程式碼與 Round 7 凍結時相同

- [x] 11.1 效能測試改用單調時鐘、5 秒上限並斷言輸出；補「cap 之後是空白」的切點案例、中段預算耗盡與尾段窗口邊界的案例；最壞情況測試加入「遮罩擴張＋六位元組跳脫」混合（finding 1／2／5／7／13）。驗證：`TemplateExtractorTests.testTheMatchersWorkIsBoundedOnAdversarialInput`、`testTheMiddleBudgetAndTheTailWindowEdge`、`DetailedOutputTests.testEachSafeCutPointIsNeeded`；變異檢查：拿掉「cap 之後是空白」的判斷、或把中段預算改成無上限，各自讓測試變紅。
- [x] 11.2 spec：工作量的措辭改成「每個候選與候選數量有上限、總量由 64 KiB 解析上限界住」，預算耗盡時整個事件為 `unstructured`；補 20 位整數、特製慢速輸入、U+200B、解析上限邊界的情境（finding 3／4／5／6）。驗證：`spectra validate add-mail-log-events` 通過。
- [x] 11.3 組合字元輸入的效能疑慮以實測排除（三種 64 KiB 輸入皆 ≤ 4 ms）（finding 8，記入 design）；canonical equivalence 造成的窗口差異只會偏向 `unstructured`，不會誤報（finding 9）。
- [x] 11.4 live 腳本 3a 恢復比對 args 與 activity（與參考分頁逐筆比完整組），並註明 `CUT_WS` 的假設；design 註明截斷規則在真實日誌上尚未驗證（finding 11／12／20／26）。
- [x] 11.5 CHANGELOG 括號位置修正（finding 10／15）。

