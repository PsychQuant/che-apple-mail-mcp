# 逾時之後：訊息只能給查證步驟，不能給判決（#522）

## 規則

GUI 流程或草稿刪除逾時之後，Mail 端已接受的 Apple Event 有沒有完成，這個 server 不知道。
訊息可以告訴呼叫端**去哪裡找證據**，不可以替呼叫端下結論。下列三條都是封閉列舉；
**不得依性質相似類推第四條**，要加就先改本檔。

1. **只有正面觀察算證據。** 逾時後可以被當作觀察的來源只有兩個：
   - `search_emails`（讀 Envelope Index）回傳一列符合的資料；
   - `list_drafts`（問 Mail）回傳一列符合的草稿。

   「沒看到」不論來自哪個來源，都不得報告成「沒寄出」「沒存」「沒發生」。
   `get_mail_log_events` 不在這兩個來源內（它是事件不是狀態，見 `r-must-direct-db.md`）；
   Outbox 也不在內（目前沒有任何讀取它的路徑，design D4 刻意排除）。
2. **不得放寬寄出閘門。** 下列三件事一個字都不動：
   - `unknownSendStateError` 的 `UNKNOWN` 與 `NOT retrying` 兩句，以及 compose、reply、forward 三個站點
     的 `isPostDispatchError(error) || isTimeoutError(error)` 條件式；
   - `isTimeoutError` 與 `isPostDispatchError` 的分類（訊息可以附加文字，但回傳的錯誤仍是既有的
     `MailError.scriptFailed`、code -1，不以 `POSTDISPATCH:` 開頭，也不是 `scriptTimedOut`）；
   - 逾時秒數（45 / 90）與 `ScriptTimeoutExecution`。
3. **不得新增 sent / not-sent 判決。** 不論是訊息詞彙、回傳欄位還是函式：沒有關聯標記
   （mailto 交接與 GUI 流程都無法設定 Message-ID 或自訂標頭，在本文放標記又會改動使用者的信），
   所以任何比對都只是「主旨 + 時間窗」的啟發式，同主旨的另一封信會讓比對不唯一。

## 現況與選項

#522 的三個選項：

| 選項 | 內容 | 狀態 |
|------|------|------|
| A | 記錄邊界，讓逾時訊息附上可執行的查證步驟 | **已做**：`TimeoutOutcomeHint.swift`、README「After a timeout」 |
| B | A ＋ 逾時錯誤後自動附加唯讀、只讀 SQLite 的觀察段落 | **沒做**，等下面的 S1–S3 量測結果；要做就另開 issue、走更重的審查 |
| C | 輸出 sent / not-sent 判決 | **不做**（違反上面第 1、3 條） |

若日後做 B：觀察的時間預算另計、上限 10 秒、只讀 SQLite（GUI 已佔 90 秒；repo 內註解假設 client 閒置上限
約 120 秒，#536 的記錄卻顯示某版 Claude Code 為 1800 秒，兩者不一致，預算以較保守者為準）。
附加的段落必須用「觀察到 / 未觀察到（不能下結論）」的詞彙，並證明 `unknownSendStateError` 的
`UNKNOWN` / `NOT retrying` 與 `isTimeoutError` 分類完全不變。

## S1–S3 量測協議（重評選項 B 的唯一入口）

下面是 #522 的 Diagnosis 留下的協議。Diagnosis 只存在 issue 留言，不寫進 repo 就會遺失，所以收在這裡。
**只用維護者自己的測試帳號、只寄給自己**（見 `CLAUDE.md` 的測試收件人規則）；量測結果寫進 issue，不寫進本檔。

- **S1**：`create_draft` 完成存檔後，Envelope Index 出現對應列的延遲。分別在 Gmail、iCloud、Exchange
  各類型帳號量 10 次。
- **S2**：寄給自己的信，寄件備份那一列出現的延遲與欄位；是否有不保存寄件備份的帳號類型。
- **S3**：離線時寄給自己的信（訊息停在 Outbox）：Envelope Index 的 `mailboxes` 表有沒有對應 Outbox 的列、
  `messages` 表有沒有那封信。

**判讀門檻**：

- 某帳號類型在 10 次中**都**於 10 秒內出現正面證據，且 `subject` ＋ 時間窗在測試範圍內唯一
  → 該類型可考慮做選項 B。
- 有延遲超過 30 秒、缺列，或不唯一 → 該類型維持 UNKNOWN。

在量測結果出來之前，訊息**不得**寫延遲數字、不得保證有寄件備份，也不建議 `date_from`（`search_emails`
的日期過濾是 `date_received`，草稿與寄件備份那一列的這個欄位是否可靠，要靠 S1 / S2 才量得出來）；
hint 改為叫呼叫端讀結果裡的 `date_received`。

## 守門測試與它們抓不到的

`Tests/CheAppleMailMCPTests/TimeoutOutcomeHintTests.swift` 與 `ReplyForwardUnknownStateTests.swift`。
它們會轉紅的情況**只有以下這些，不得依性質相似推論其他改動也會被擋**：

- hint 的位置：寄出類訊息（compose 的逾時與 post-dispatch 兩個分支、reply、forward）的 hint 不在 `Original error:` 之前（回填被截在 200 字元，hint 放後面會被切掉）；
- 任一 `TimeoutOutcomeKind` 的 hint 變空、缺 `search_emails`、缺 `field="subject"`、缺否定句
  （`NOT evidence` / `does not prove` / `not a confirmation` 三者之一）；
- hint 文字（不分大小寫）含這些詞：`safe to retry`、`safe to resend`、`safe to re-send`、`confirmed sent`、
  `was not sent`、`not sent`、`has been sent`、`definitely`；
- 寄出類 hint 不含 `Do not resend automatically`、`Full Disk Access`、`date_received`，或含 `date_from`；
- 草稿刪除逾時的訊息含 `GUI` 或 `read-only`，或不含 `deletion outcome is unknown`；
- `.subprocess` 逾時描述不含 draft-save 的 hint；
- reply / forward 的訊息措辭在 hint 之前有任何改動，或 `MailController.swift` 又出現內嵌的那段措辭；
- README 的「After a timeout」一節不存在，或沒提到 `search_emails`、`list_drafts`、`UNKNOWN`。

抓不到的：`isTimeoutError` / `isPostDispatchError` 本身被改（由既有的 `GuiScriptTimeoutTests` 與
`WrapperFreeRouteTests` 的計數守門負責，不是本檔的測試）；hint 以外的句子被寫成判決；README 表格內的
其他欄位漂移。審查時要自己讀 diff，不能只看測試綠燈。

## 為什麼

#415 把逾時診斷分成「interpreter 已退出」與「未確認退出」，並明說終止 interpreter 不會撤回已送進 Mail 的
Apple Event。Mail 端那個 Apple Event 最後有沒有完成，沒有可靠的來源：Envelope Index 是非同步寫入的，
不保存寄件備份的帳號永遠沒有那一列，`search_emails` 自己也可能在暫時性錯誤或並行時靜默回空
（#549、#536）。呼叫端若把「沒搜到」讀成「沒寄出」就會重寄，而重寄正是 `NOT retrying` 要擋的事。
所以訊息只提供「可以看哪裡」與「看到、沒看到各代表什麼」，把決定留給使用者。

## 相關

- #522（本規則的出處）、#415（residue 來源）、#550（reply / forward 逾時措辭的過度宣稱，另案修）
- `r-must-direct-db.md`（`get_mail_log_events` 不是狀態來源）
- `deferred-live-verification.md`：選項 A 不宣稱延遲、不保證有寄件備份，因此沒有 KNOWN GATE 要記

本規則只放在本 repo 的 `.claude/rules/`，不複製到 `plugin/rules/` 或全域鏡像：呼叫端最可靠的管道是錯誤訊息
本身；`compose-wrapper-free.md` 的失敗表是封閉的六類事前拒絕，逾時不在其中，不加第七列。
