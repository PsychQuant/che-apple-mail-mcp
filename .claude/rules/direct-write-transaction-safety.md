# 直接寫入草稿：以交易安全為準，速度不得換掉它

## 規則

opt-in 直接寫入（`create_draft` + `CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1`，#472／#475）的任何改動——
**包括所有以「變快」為目的的改動**——都不得削弱下列保證。這份清單是封閉的；
**任何一條被削弱，該改動就不做，不論省下多少時間。**

1. **單一交易**：寫入只發生在一個 `BEGIN IMMEDIATE` 交易內，`.emlx` 在交易內原子改名；
   交易內任何失敗都整筆還原並刪檔，不留半套狀態。
2. **觸發前精確還原**：上傳請求（切換草稿已讀狀態）成功完成之前的任何失敗，都必須先精確還原寫入，
   才可以改走 GUI 路徑。
3. **觸發後不退回**：上傳請求成功之後，絕不改走 GUI 路徑（會產生第二份草稿）。
4. **寫入前閘門每次照跑**：spec〈Direct-write draft path〉的 10 項適用條件與 9 項寫入前閘門，
   每次呼叫都依序以**當下**的 Mail 版本與資料庫狀態檢查。cache 或任何先前結果只能提供候選值，
   不能取代閘門的檢查；候選值對不上當下資料庫時，視為沒有 cache。
5. **不碰 Mail 自己維護的欄位**：不寫 `alleged_change_identifier`，計數交給 Mail 的 trigger。
6. **結果只陳述觀察到的事**：只有確認上傳後才可回報「已上傳」；沒有確認就回報待定或未確認，
   不預測 Mail 何時會上傳。
7. **上傳確認與已讀補設不得省略**：觸發後等待上傳確認的那段，負責發現「草稿沒有上傳」與補回本機
   副本的已讀狀態（#482）。拿掉它等於讓工具在草稿可能只存在本機時回報成功。等待上限是 10 秒，
   從送出上傳請求**之前**起算，所以觸發本身花掉的時間也算在這 10 秒內。縮短上限是同一類改動：
   上限太短，補設已讀就不會執行（它只在確認上傳後才跑）。要縮短，先拿出觸發耗時與上傳確認時間的
   分布作為證據（觸發的分解計時見 #489）。
8. **已讀切換的間隔是實驗中可行的值，不是可調參數**：兩次切換之間是 0.5 秒。可查的紀錄只有這些：
   - #472 寫明 0.5 秒是「#463 驗證過」的值；但 #463〈Round 2 補充（輕量觸發）〉那則 comment 沒有寫出
     間隔，原始值只留在本機實驗腳本，不在 repo。那則 comment 裡切換草稿**自己**已讀的只有 I4 一次
     （I3 切換的是垃圾桶裡的探針副本）。
   - #472 用過 0.3 秒，兩封草稿中有一封的本機副本留在未讀（伺服器端已讀）。改回 0.5 秒後 D3–D6
     四封都已讀，但那時已同時加上補設已讀，結果不能只歸功於間隔。

   所以 0.5 秒是「已知可行」，不是「已知的下限」。要縮短，必須先用測試帳號重做 live 實驗（每個候選值
   至少 10 次，#488），把次數、結果與本機／伺服器兩端狀態寫進 issue，證明不會出現未讀殘留或重複
   草稿，才可以改。
   - #488（2026-10-06）已做過一次：0.5、0.4、0.3、0.2、0.1 秒各 10 封，全部成功；但 0/10 的單側 95% 上限
     約 26%，不足以證明更短的間隔安全，使用者決定維持 0.5 秒。材料、限制與重跑方法在
     `scripts/experiments/488-toggle-gap/`。

## 怎麼判斷一個加速提案能不能做

逐條對照上面 8 項：**全部不受影響才做。** 只要有一項被削弱，就不做；不要用「機率很低」「多數情況沒事」
當理由，那正是這條規則要擋的判斷。

第 7、8 項有守門測試（`Tests/CheAppleMailMCPTests/DirectWriteSafetyGuardTests.swift`，#490）。它們是
觸發 script 與原始碼的**結構檢查**，不是行為測試（行為測試見下方第 2、3、6 項）。這兩條守門測試會轉紅的
情況**只有以下這些，不得依性質相似推論其他改動也會被擋**：

- **第 8 項**（解析觸發 script；比對前去掉 AppleScript 註解，字串內容清空，關鍵字不分大小寫）：
  - 兩次切換之間的 `delay` 數字總和低於 0.5 秒；
  - 兩次切換之間有一行以這些字開頭：`if`、`repeat`、`try`、`considering`、`ignoring`、`tell`、`with`、
    `using`、`on`、`error`、`return`、`exit`、`end`；或有一個 `delay` 後面不是單純的數字；
  - `set read status of` 在整個 script 裡不是恰好出現兩次（不分大小寫、不論對哪個變數），或這兩次不是
    逐字的 `set read status of _m to false` 在前、`set read status of _m to true` 在後。
- **第 7 項**（比對 `Sources`；比對前去掉 Swift 註解與縮排）：
  - `uploadDeadline` 的預設值低於 10；
  - `Sources` 裡提到 `uploadDeadline` 的程式碼行，與這三行不完全相同：預設宣告、等待迴圈條件、待定回報。
    所以在其他地方用到它（例如在呼叫端覆寫），或改寫這三行的任何文字，都會轉紅；
  - `Sources` 裡提到 `ensureRead` 或 `attemptSteps(` 的程式碼行，不是恰好它們的宣告與唯一的呼叫
    （例如宣告同名的局部閉包、改呼叫一份複製出來的函式）；
  - `attemptSteps` 從 `timer.mark("inserted")` 到函式結尾 `}` 的程式碼行，或 `ensureRead` 整個函式，
    有任何一行被新增、刪除、改動、註解掉或換順序；或這兩段的結尾 `}` 之後，下一行不是以 `func `、`static func `、
    `private func `、`private static func `、`fileprivate func `、`fileprivate static func ` 或 `@` 開頭
    （例如把整段包起來、在後面補上提早回報）；或前一段不在 `attemptSteps` 裡。這兩段是整段凍結的：
    要改它們（例如 #489 加計時點），必須在同一個 commit 更新測試裡的凍結副本，審查時逐行對照
    第 2、3、6、7 項。

上面沒列到的改動，都不會讓這兩條守門測試轉紅。凍結段呼叫到的函式不在它們的範圍內；其中另有測試的只有
`readOutcome`、`outcomeAfterFailedTrigger`、`buildDirectDraftMarkReadScript`、`buildDirectDraftTriggerScript`
（`DirectDraftPathTests`）、`triggerDirectDraftUpload`（`DirectDraftTriggerTimingTests`，#489：斷言它送出的
就是 `buildDirectDraftTriggerScript` 在同一個 `timing` 下的輸出）與 `uploadState`（`DraftStoreWriterTests`；讀取失敗見 `DirectDraftPathOutcomeTests`，#630），
`readFlag` 與 `createdText` 由 `DirectDraftPathOutcomeTests` 走過（#484；`readFlag` 讀取失敗寫 stderr、找不到列不寫，也在那裡，#653），`markDirectDraftRead` 在那裡是替身，真的那個沒有測試。

結構檢查擋不住所有削弱方式。#490 第 4 輪驗證找到下列六種寫法，這兩條守門測試都不會轉紅。#492 之後，每一種都有別的測試會轉紅，列在各項後面，都實際改過原始碼確認：

1. 在 `timer.mark("inserted")` 之前提早回報：`DirectDraftPathOutcomeTests` 的結果與步驟序列；
2. 讓 `triggerDirectDraftUpload` 送出 `buildDirectDraftTriggerScript` 以外的 script，或在送出前改寫它：
   `testTriggerSendsTheBuildersScriptForItsTimingFlag`；
3. 在 `DirectDraftPath` 裡宣告與凍結段所用名稱同名的型別或函式（例如 `Task`）：
   把 `Task.sleep` 變成空的，`testTheReadRepairGivesMailTimeBetweenItsLooks` 會轉紅；
4. 用 `set the read status of` 之類的寫法多加一次切換：`testUntimedTriggerScriptIsUnchanged`；
   只在計時時才多加的，`testTimedTriggerIsTheUntimedOnePlusItsMarks`；
5. 用 `if` 等控制流程包住兩次切換：同第 4 項；
6. 另寫一條名稱不同、不經 `attemptSteps` 的平行路徑：再開一次 `DraftStoreWriter(` 或再寫一次 `writer.insert(`，
   `testTheStoreIsOpenedAndWrittenInOnePlace` 會轉紅。

這些測試已知還抓不到下列寫法，不代表只有這些：

- 第 1 項：條件只在測試情境以外成立的提早回報；
- 第 3 項：只讓上傳輪詢不等待的宣告（補設已讀的等待照舊）；把等待縮短但沒有變成空的宣告（約 90 ms 以上，八次查看仍涵蓋 0.6 秒）；宣告 `Task` 以外的名稱，例如 `Date`；
- 第 4 項：藏在 `ComposeTiming.prelude` 或 `markStatement` 裡、只在計時時執行的切換；
- 第 6 項：用別的名字沿用已開的 writer；寫成 `DraftStoreWriter.init(` 或把 `.insert(` 換行；把平行路徑放進 `DraftStoreWriter.swift`；不經 `DraftStoreWriter` 寫入 store。

測試轉紅時，先取得上面要求的證據並更新本規則，再改測試；不要只改門檻或凍結副本。

第 1–6 項沒有像第 7、8 項那樣的守門測試。各項目前的覆蓋（#498）：

- **第 1 項**：`DraftStoreWriterTests` 與 `DraftStoreWriterDirectoryTests` 有測交易內失敗的行為測試，只涵蓋 writer 本身，不涵蓋 `attemptSteps` 怎麼呼叫它：
  - 檔案寫不進去（`testInsertLeavesNothingBehindWhenTheFileCannotBeWritten`）；
  - `.emlx` 放好之後才失敗（`testInsertRemovesThePlacedFileWhenALaterStepFails`）：檢查放檔已執行（writer 只給測試用的放檔掛點在檔案放好時看到它）、writer 的交易確實結束（另一條連線拿得到寫入鎖）、沒有留下任何資料列、檔案或這次建立的目錄。拿掉 ROLLBACK、拿掉刪檔、把失敗移到放檔之前、或拿掉目錄清理，這條都會轉紅。
  - 放檔時建立的目錄（#503）：只記下這次 `mkdir` 自己建立的層，寫入失敗（放檔之後、或放檔途中）與 commit 之後的 `rollback()` 都以 `rmdir` 由深到淺移除：已不存在的層略過、繼續往上；停在第一個仍然存在卻移除不了的層（不是空的，或其他原因；「不是空的」與「已不存在」以外的原因寫到 stderr）。清理不改變拋出的錯誤、也不讓 `rollback()` 失敗。`DraftStoreWriterDirectoryTests` 用合成的 store 測（不需 Full Disk Access）：放檔之後失敗、放檔途中失敗、還原三種情況都移除新建的層，原本就存在的層保留，新建目錄裡多了別的檔案時（失敗與還原各一條）連同上層都保留，目標路徑已有 `.emlx` 時不動它，已不存在的 `Messages` 不擋住上層的清理，權限造成的移除失敗寫到 stderr 並停下（#503 fix round 1）。
  - 殘留競態（#503）：清理移除這次建立的空目錄時，Mail 若剛好找到這個目錄、還沒寫檔，移除可能早於 Mail 寫檔。前提是這次失敗的寫入是該 Drafts mailbox 在這個千位區塊的第一列：row id 全域共用、雜湊目錄卻是每個 mailbox 各自一份，所以 Drafts 訊息少時這很常見，不是罕見情況。另有兩項在 #666：`insert` 的清理在 `ROLLBACK` 之後才做（重用 row id 的同一路徑），以及目錄只以路徑記錄、不比對身分。
  - 缺口：交易一開始就拿寫入鎖（`BEGIN IMMEDIATE`）沒有測試，改成一般的 `BEGIN` 這些測試都不會轉紅；「別的程序先建立的層不記錄」（`EEXIST`）沒有測試（#666）。
- **第 2、3、6、7 項**：`DirectDraftPathOutcomeTests`（#484）走真的 `attemptSteps` 與真的 `DraftStoreWriter`，只有 Mail 是替身，store 是測試自己建的 SQLite 檔（有 writer 驗證的表與欄位，沒有 Mail 的 trigger）。替身照 Mail 改真 store 的方式改那個檔。這批測試斷言結果代碼與 `direct` 步驟序列：
  - 上傳確認 → `created`，步驟走到 `uploaded`、`read_ensured`；
  - 上傳期限內沒有確認 → `created:upload_pending`，不走 GUI 路徑，不回報已上傳；
  - 有 `remote_id` 但排隊動作讀不到 → `created:upload_pending`，不回報已上傳；讀取在期限內恢復 → 等到恢復才確認（#630）；
  - 觸發失敗 → 先還原才走 GUI 路徑一次，還原的結果在 GUI 路徑裡檢查（`rollback()` 涵蓋的資料列與 `.emlx` 都不留；它不還原的列見 #628）；
  - 觸發失敗但 Mail 已上傳 → 還原被拒，回 `created`，不走 GUI 路徑；
  - 觸發失敗且還原因其他原因失敗 → `created:upload_pending`，回報上傳未確認；
  - 上傳後仍未讀 → 補設已讀一次；補設無效 → 帶 note，沒有 `read_ensured`。

  另有純函式的單元測試（`outcomeAfterFailedTrigger` 三條、`readOutcome`）、`createDraft` 層的一條（`testACreatedDirectDraftSkipsTheGuiPath`），以及 writer 端的三條：提交後的 `rollback()` 會還原它涵蓋的資料列與 `.emlx`（`testInsertWritesEveryRowAndTheFileThenRollbackRestoresAll`，不涵蓋的見 #628）、Mail 已上傳就拒絕還原（`testRollbackRefusesOnceTheServerHasTheMessage`）、讀不到上傳狀態也拒絕還原且不刪任何東西（`testAFailedUploadCheckRefusesTheRollbackAndDeletesNothing`，#618）。這批測試證明的是 `attemptSteps` 的分支，不是 Mail 的真實行為；後者仍靠 live 驗證。
- **第 4 項**：`DirectDraftPathTests` 有三種寫入前結果的行為測試：旗標關、一種不符條件（cc/bcc）、版本閘門（讀不到 Mail 版本）；`DirectDraftPathOutcomeTests` 另有三種（作業系統版本不符、帳號有簽名、store schema 漂移），都斷言 store 沒有被動過、沒有觸發。writer 端另有一條：找草稿匣的掃描中途失敗時不回傳部分結果（`testAMailboxScanThatFailsAfterTheMatchAnswersNothing`，#618）。其餘條件與閘門只測了結果代碼與文字，也沒有測試證明每次呼叫都依序跑完全部閘門。「cache 不能取代閘門」要等 cache 存在才有東西可測（#487）。
- **第 5 項**：沒有測試，見 #491。

已評估過的提案（2026-10-05，live 計時：直接寫入 3.17 秒，其中寫入 14 ms、找草稿匣 470 ms、
觸發 1,667 ms、等上傳確認 1,021 ms）：

| 提案 | 結論 | 依據 |
|---|---|---|
| cache 草稿匣辨識結果（省約 470 ms） | **可做** | 只要第 4 項成立：cache 只給候選路徑，9 道閘門照跑、用當下資料庫驗證，對不上就重新辨識 |
| 觸發後不等上傳確認（省約 1 秒） | **不做** | 違反第 6、7 項：無法發現沒上傳的草稿，也不再補設已讀 |
| 縮短兩次已讀切換的間隔 | **不做（實驗後維持 0.5 秒）** | 第 8 項：#488 已做 live 實驗（5 種間隔各 10 封全部成功，但 0/10 的單側 95% 上限約 26%），使用者決定維持 0.5 秒；要再縮短，須先有更大的樣本 |
| 觸發改成 in-process（省下啟動 osascript 的時間，#496） | **不做** | 第 2、3 項：in-process 沒有終止機制，逾時只能放棄 thread，script 仍可能在還原之後才切換已讀。以單行 script 推算每次約可省 65–140 ms（觸發 script 本身沒有量過；#406 記錄過草稿掃描 script 在背景 NSAppleScript 反而超過 50 秒）。#489 的 198 ms 裡，計時本身推估約佔 45–120 ms（跨負載相減，`scripts/experiments/496-trigger-transport/`） |
| 縮短上傳確認的輪詢間隔（250 → 100 ms，#497） | **可做（已做）** | 8 項都不受影響：迴圈在觸發成功之後、只讀資料庫，10 秒上限、起算點與補設已讀都不變。效益是推導值：平均早約 75 ms 發現上傳；10 封 live 驗證每封都只有一份、都確認上傳且已讀，但量不出這麼小的差距（`scripts/experiments/497-upload-poll/`） |

## 為什麼

直接寫入的價值是「不開視窗、結果可信」，不是快幾百毫秒。GUI 路徑慢，但它的失敗都是看得見的；
直接寫入繞過了 Mail 的編輯器，一旦交易或觸發的保證鬆掉，壞掉的方式是安靜的——重複草稿、只在本機的
草稿、本機與伺服器狀態不一致——而且使用者看不出來。這些都比慢一秒貴得多。

這條規則寫下來，是因為 2026-10-05 分析計時時，「不等上傳確認」與「縮短切換間隔」都被列成加速選項；
兩者單看都合理，合起來就是把上面第 6、7、8 項換成速度。

## 相關

- `r-must-direct-db.md` 〈C/U/D 的唯一例外〉——直接寫入的適用界線與「觸發」的定義
- `openspec/specs/message-composition/spec.md` 〈Direct-write draft path〉——10 項條件與 9 項閘門（以 spec 為準）
- #463 / #472（實驗與原型）、#475（spec 化）、#482（本機副本未讀）、#481（是否設為預設）
- #488（切換間隔的 live 實驗）、#489（觸發步驟的分解計時）、#490（本規則的出處修正與守門測試）

本規則只放在本 repo 的 `.claude/rules/`，不複製到 `plugin/rules/` 或全域鏡像：它約束的是維護者怎麼改
直接寫入，不是呼叫端怎麼使用這個 MCP（#490）。
