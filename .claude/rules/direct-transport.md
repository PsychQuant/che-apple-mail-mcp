# 直接傳送（send_draft）：不經 Mail 寫到伺服器，以這八項保證為準（#742）

## 規則

`send_draft`（`Sources/CheAppleMailMCP/DirectTransport/`）不經 Mail，直接用 IMAP 與 SMTP 對伺服器讀寫。
它的任何改動，**包括以「變快」或「更方便」為目的的改動**，都不得削弱下列保證。這份清單是封閉的；
**任何一條被削弱，該改動就不做**，不得依性質相似推論別的保證也可以放寬。規格以
`openspec/specs/direct-transport/spec.md` 為準，這裡不重抄條件，只列不能動的部分。

1. **只限設定過的帳號，沒有退路。** 只有 `direct-transport.json` 列出的帳號能用；其他帳號、設定檔讀不到或
   格式錯誤，一律在開任何連線之前拒絕，**不改走 Mail 的任何路徑**。
2. **密碼只來自伺服器自己的 keychain 項目。** service 是 `che-apple-mail-mcp.direct-transport`。不讀 Mail 或
   其他程式的項目；密碼不出現在任何工具參數、工具結果、stderr、log 或伺服器寫的檔案裡；只有命令列模式
   `--direct-transport-set-credential` 能建立或取代它，沒有任何 MCP 工具能建立、修改或讀出它。
3. **送密碼之前一定先有 TLS。** 465 與 993 用 implicit TLS，其他連接埠一律要求 STARTTLS（伺服器不提供就失敗）；
   憑證完整驗證、TLS 至少 1.2。不得用 `.automatic` 或 `.plainText`（#742 的 commit 安全審查抓過一次）。
4. **參數封閉，不能寫內容。** 只接受 `account_name`、`account_id`、`draft_id`、`subject_match`；其他參數一律
   具名拒絕。送出的就是伺服器存的草稿去掉 Bcc 欄位，工具不改寫任何一個字。
5. **提交前的檢查每次照跑。** 規格列的五項（Message-ID、已寄出紀錄、寄件人、收件人、標頭可去 Bcc）依序以
   **當下**的草稿與紀錄檢查；先前的結果不能取代。
6. **同一份草稿不送兩次。** 開始交易之前先在紀錄裡以 Message-ID 佔位（`attempting`）；開始時看到 `attempting`
   一律當 `unknown`。`unknown` 不重試，只有命令列模式 `--direct-transport-forget` 能清掉；`submitted` 的紀錄
   不能被清掉（清掉就能再送一次）。
7. **`not_sent` 只來自伺服器在接受之前的明確答覆。** 只有 SwiftMail 記為 provably not accepted 的情況
   （`notAccepted`、`rejectedTransiently`、`rejectedPermanently`，以及交易開始前才會丟的 `SMTPError`）算
   `not_sent`；其他一切，包括不認得的錯誤，預設 `unknown`。不得把「連線斷了」「沒收到回覆」推論成沒寄出。
   `unknown` 的說明只講去哪裡查（收件人的信、寄件備份），不說寄了或沒寄。
8. **提交後的階段不會重新提交。** 寄件副本與移除草稿是提交之後的兩個階段，失敗就留 `pending` 讓下次呼叫補做；
   補做的路徑不得再走 SMTP。移除草稿只在寄件副本不再 `pending`、且伺服器支援 UIDPLUS 時，以 UID 移除那一封，
   不得用會清掉其他已刪除郵件的 `EXPUNGE`。

## 與其他規則的關係

- `r-must-direct-db.md`：那裡的「C/U/D 唯一例外」講的是寫進 Mail **本機** store（Envelope Index、`.emlx`）。
  `send_draft` 不碰本機 store，寫的是伺服器；Mail 下次同步時自己跟上。所以它不是那份清單的第二個例外，
  也不得拿來當「可以寫本機 store」的前例。
- `timeout-outcome-boundary.md`：那裡禁止的 sent／not-sent 判決，前提是交給 Mail 的 Apple Event 沒有任何
  關聯標記可查。SMTP 的 `not_sent` 是伺服器對這一筆交易的直接答覆，第 7 條把它限縮在 SwiftMail 能證明的情況；
  這不是那份封閉列舉的例外，也不得拿來在 GUI 路徑上加判決。
- `deferred-live-verification.md`：`send_draft` 還沒對真實伺服器跑過。在結果記到 #742 之前，#742 保持 OPEN 並
  貼 `blocked-on-setup`，工具說明保留「NOT YET RUN AGAINST A REAL MAIL SERVER」那一句（`SendDraftToolTests` 釘住）。
  live 測試只能寄給維護者自己（`CLAUDE.md` 的測試收件人規則）。

## 守門測試與它們抓不到的

會轉紅的情況（封閉列舉，不得依性質相似推論其他改動也會被擋）：

- 第 3 項：`SwiftMailSession.transportSecurity(forPort:)` 對 465、993 以外的連接埠不回 `.startTLS`，或對這兩個
  不回 `.implicitTLS`（`SubmitOutcomeClassificationTests`）；
- 第 4 項：`send_draft` 接受清單以外的參數（`SendDraftToolTests`）；
- 第 6 項：`--direct-transport-forget` 清掉 `submitted` 的紀錄（`DirectTransportCLITests`），或流程對 `unknown`／
  `attempting` 的紀錄再次提交（`SendDraftFlowTests`）；
- 第 7 項：`classify` 把 `ambiguous` 或不認得的錯誤分成 `not_sent`（`SubmitOutcomeClassificationTests`）；
- 說明的 caveat 被拿掉（`SendDraftToolTests`）。

抓不到的：`SwiftMailSession` 對真實伺服器的行為（連線參數是否真的被 SwiftMail 套用、`\Drafts` 屬性是否出現在
`LIST` 的結果、UIDPLUS 的判斷）都沒有測試，只能靠 live 測試；把 `minimumTLSVersion` 或
`certificateVerificationPolicy` 改鬆也不會讓測試轉紅。審查時要自己讀 diff。

## 為什麼

直接傳送的價值是「不必開 Mail 也能寄」，壞掉的方式卻是安靜的：送兩次、密碼經過明文、把不確定說成沒寄出。
這些都不能靠事後補救，所以寫成不能動的清單。
