# 直接傳送（send_draft、append_draft）：不經 Mail 寫到伺服器，以這些保證為準（#742、#744）

## 規則

`send_draft`（`Sources/CheAppleMailMCP/DirectTransport/`）不經 Mail，直接用 IMAP 與 SMTP 對伺服器讀寫。
它的任何改動，**包括以「變快」或「更方便」為目的的改動**，都不得削弱下列保證。這份清單是封閉的；
**任何一條被削弱，該改動就不做**，不得依性質相似推論別的保證也可以放寬。規格以
`openspec/specs/direct-transport/spec.md` 為準，這裡不重抄條件，只列不能動的部分。

1. **只限設定過的帳號，沒有退路。** 只有 `direct-transport.json` 列出的帳號能用；其他帳號、設定檔讀不到或
   格式錯誤，一律在開任何連線之前拒絕，**不改走 Mail 的任何路徑**。
2. **密碼只來自伺服器自己的 keychain 項目。** service 是 `che-apple-mail-mcp.direct-transport`。不讀 Mail 或
   其他程式的項目；密碼不出現在任何工具參數、工具結果、stderr、log 或伺服器寫的檔案裡；只有命令列模式
   `--direct-transport-set-credential` 能建立或取代它，沒有任何 MCP 工具能建立、修改或讀出它。取代時一律新增
   本程式自己的項目（已存在就刪掉再新增），**不得**用 `SecItemUpdate` 寫進既有項目：那個項目可能是別的程式以同一個
   service 建的，存取清單讓它讀得到。工具結果與紀錄裡的錯誤文字與伺服器回覆，先整段遮蔽密碼（原文、IMAP quoted
   string、AUTH PLAIN／LOGIN 的 base64）**再**截斷；先截斷會留下密碼的前半段。伺服器回報的草稿欄位（Message-ID、
   主旨、位址）若含密碼，整個呼叫拒絕。
   已知殘留（#742 verify r2、r3）：讀取時只以 service 與 account 比對，別的程式若先以同樣名稱建了項目，讀到的會是它的值，
   並以它登入設定的伺服器。它拿不到我們的密碼（寫入一律新增本程式自己的項目），但它自己放進去的值會被送到設定的伺服器；
   規格明寫這個殘留，不宣稱已擋住。根本解法是 data-protection keychain，要 entitlement 與 provisioning profile，
   這次不做。
3. **送密碼之前一定先有 TLS。** 465 與 993 用 implicit TLS，其他連接埠一律要求 STARTTLS（伺服器不提供就失敗）；
   憑證完整驗證、TLS 至少 1.2。不得用 `.automatic` 或 `.plainText`（#742 的 commit 安全審查抓過一次）。SMTP 只在
   檢查都通過、寫佔位之前才連線登入；只補做提交後階段的呼叫不連 SMTP。
4. **參數封閉，不能寫內容。** 只接受 `account_name`、`account_id`、`draft_id`、`subject_match`、`message_id`
   （#744；三個選擇器恰好給一個）；其他參數一律具名拒絕。送出的就是伺服器存的草稿去掉 Bcc 欄位，工具不改寫任何一個字。
5. **提交前的檢查每次照跑。** 規格列的六項（Message-ID、已寄出紀錄、寄件人、收件人、標頭可去 Bcc、不是 Mail 的草稿版面，#745）依序以
   **當下**的草稿與紀錄檢查；先前的結果不能取代。UID 只在草稿匣的 UIDVALIDITY 沒變時使用；搜尋到卻取不到
   envelope 的候選讓整個呼叫失敗（略過它會讓兩封看起來像一封）；標頭有 To／Cc／Bcc／From 欄位而 envelope 沒有
   位址，算成無效。
6. **同一份草稿不送兩次。** 開始交易之前先在紀錄裡以 Message-ID 佔位（`attempting`）；開始時看到 `attempting`
   一律當 `unknown`。`unknown` 不重試，只有命令列模式 `--direct-transport-forget` 能清掉；`submitted` 的紀錄
   不能被清掉（清掉就能再送一次）。一次只跑一個 `send_draft`：從開 IMAP 連線到關閉都持有提交鎖（flock，
   `O_CLOEXEC`，程式結束就釋放）；佔位寫入後先 fsync 檔案與目錄，才開始 SMTP 交易；forget 在鎖被持有時一律不清，而且「檢查狀態」與「刪除」在紀錄鎖內是同一步。伺服器已經回答
   之後寫紀錄失敗，結果照樣回報伺服器的答覆，並說明紀錄沒更新；留著的 `attempting` 讓之後的呼叫當成 unknown，
   不會再送。
7. **`not_sent` 只來自伺服器在接受之前的明確答覆。** 只有 SwiftMail 記為 provably not accepted 的情況
   （`notAccepted`、`rejectedTransiently`、`rejectedPermanently`，以及交易開始前才會丟的 `SMTPError`）算
   `not_sent`；其他一切，包括不認得的錯誤，預設 `unknown`。不得把「連線斷了」「沒收到回覆」推論成沒寄出。
   `unknown` 的說明只講去哪裡查（收件人的信、寄件備份），不說寄了或沒寄。
8. **提交後的階段不會重新提交。** 寄件副本與移除草稿是提交之後的兩個階段，失敗就留 `pending` 讓下次呼叫補做；
   補做的路徑不得再走 SMTP。補做只在呼叫的帳號就是提交的帳號、而且取到的草稿位元組與提交時的 SHA-256 相同時
   才做，帳號還要是同一個登入與 IMAP 伺服器；否則拒絕，什麼都不存也不刪。存寄件副本前先查寄件備份裡有沒有
   Message-ID **完全相同**的一封（IMAP 的標頭搜尋是子字串比對，命中不算數），有就記為完成、不存第二份。紀錄還寫著
   寄件副本 pending 時不移除草稿：草稿是那份位元組唯一的另一個來源。
   移除草稿只在寄件副本不再 `pending`、且伺服器支援 UIDPLUS 時，以 UID 移除那一封，不得用會清掉其他已刪除郵件的
   `EXPUNGE`。

## 找草稿匣與寄件備份匣（#748，兩個工具共用）

14. **不憑信匣名稱挑信匣。** 草稿匣與寄件備份匣照規格〈The drafts and sent mailboxes are found in a fixed order〉的五條依序找
   （`MailboxLookup`）：一般 `LIST` 的標記；伺服器宣告 `SPECIAL-USE` 時以 `RETURN (SPECIAL-USE)` 再問一次；仍沒有才用
   `direct-transport.json` 裡維護者寫的 `drafts_mailbox`／`sent_mailbox`（伺服器要列出完全同名的那一個）；都沒有就拒絕。
   名稱只在維護者自己寫進設定檔時才算數。伺服器沒宣告 `SPECIAL-USE` 時**不得**呼叫 SwiftMail 的
   `listSpecialUseMailboxes()`：它在那種情況會用信匣名稱推測。能力清單只在一般清單沒有標記時才取，取不到不能推翻伺服器已經給的標記。設定的名稱逐個 scalar 比對（不是 Swift 的 `==`），用伺服器列出的那個寫法。伺服器標的信匣若是 `\Noselect` 就拒絕，不改用設定的名稱；能力清單讀不到也拒絕。寄件備份匣與草稿匣是同一個時（比較時 `INBOX` 不分大小寫），寄件副本留 pending、草稿不刪。2026-11-22 的 iCloud：登入前的能力清單沒有 `SPECIAL-USE`、一般 `LIST` 沒有標 `\Drafts`；登入後的情形還沒觀察到。
   拒絕與結果的 notes 只寫數量與「有／沒有宣告」，不寫信匣名稱或能力清單。

## append_draft（#744）

`append_draft` 經 IMAP 在草稿匣建立一封新草稿。上面第 1、2、3 項照樣適用（帳號、憑證、TLS；它不連 SMTP）；第 2 項的
遮蔽在結果邊界再做一次，不依賴各個錯誤來源自己遮蔽。
另外這幾項同樣不能削弱（封閉列舉，不得依性質相似類推）：

9. **內容由工具自己組，不是 Mail 草稿的版面。** 單一 `text/plain; charset=utf-8`、CRLF；不帶
   `X-Uniform-Type-Identifier` 或任何 `X-Apple-` 欄位、不是 multipart。這封草稿會被 `send_draft` 原樣送出，
   Mail 草稿的空純文字段與草稿標頭會送到收件人手上（#745）。改成 Mail 的版面，就是把 #745 搬進這個工具。
10. **參數封閉、在開連線前檢查。** 只接受 `account_name`、`account_id`、`to`、`cc`、`bcc`、`subject`、`body`、
    `from_name`。收件人只收純位址（規格寫明的文法）；主旨與 `from_name` 的控制字元、內文的 NUL 一律拒絕：它們會變成
    標頭注入。大小上限（內文 5,000,000、主旨 2,000、`from_name` 200 octets，收件人 100）在組信之前檢查，組信在取得鎖與
    憑證之後。
11. **`not_appended` 只來自伺服器的明確拒絕或 APPEND 送出之前。** `IMAPError.commandFailed`（APPEND 的 tagged
    NO／BAD）、`appendLimitExceeded`，以及 APPEND 之前的連線、登入、找草稿匣失敗，算 `not_appended`；APPEND 送出之後的
    連線關閉、逾時、不認得的錯誤都是 `unknown`。
12. **`unknown` 不重試，只看正面觀察。** 同一次呼叫裡絕不 APPEND 第二次；之後只試一次以 Message-ID 搜尋，命中要
    逐字相同（IMAP 的標頭搜尋是子字串比對），找到才改報 `appended`。搜尋失敗與搜尋沒找到分開回報，兩者都不是「沒存」。
    沒有去重紀錄：每次都是新的 Message-ID，重複呼叫而草稿也存進去了，就多一封；說明與結果都要寫明。
13. **與 `send_draft` 共用提交鎖。** 兩個直接傳送的呼叫不同時開連線；`--direct-transport-forget` 在鎖被持有時不清。

## 與其他規則的關係

- `r-must-direct-db.md`：那裡的「C/U/D 唯一例外」講的是寫進 Mail **本機** store（Envelope Index、`.emlx`）。
  `send_draft` 不碰本機 store，寫的是伺服器；Mail 下次同步時自己跟上。所以它不是那份清單的第二個例外，
  也不得拿來當「可以寫本機 store」的前例。
- `timeout-outcome-boundary.md`：那裡禁止的 sent／not-sent 判決，前提是交給 Mail 的 Apple Event 沒有任何
  關聯標記可查。SMTP 的 `not_sent` 是伺服器對這一筆交易的直接答覆，第 7 條把它限縮在 SwiftMail 能證明的情況；
  這不是那份封閉列舉的例外，也不得拿來在 GUI 路徑上加判決。
- `deferred-live-verification.md`：`send_draft` 與 `append_draft` 都還沒對真實伺服器跑過（後者追蹤在 #744，規則相同）。在結果記到 #742 之前，#742 保持 OPEN 並
  貼 `blocked-on-setup`，工具說明保留「NOT YET RUN AGAINST A REAL MAIL SERVER」那一句（`SendDraftToolTests` 釘住）。
  live 測試只能寄給維護者自己（`CLAUDE.md` 的測試收件人規則）。

## 守門測試與它們抓不到的

會轉紅的情況（封閉列舉，不得依性質相似推論其他改動也會被擋）：

- 第 3 項：`SwiftMailSession.transportSecurity(forPort:)` 對 465、993 以外的連接埠不回 `.startTLS`，或對這兩個
  不回 `.implicitTLS`（`SubmitOutcomeClassificationTests`）；
- 第 4 項：`send_draft` 接受清單以外的參數（`SendDraftToolTests`）；
- 第 6 項：`--direct-transport-forget` 清掉 `submitted` 的紀錄，或在提交鎖被持有時清掉任何紀錄
  （`DirectTransportCLITests`）；流程對 `unknown`／`attempting` 的紀錄再次提交，或寫紀錄失敗時丟掉已知的結果
  （`SendDraftFlowTests`）；
- 第 8 項：補做不核對帳號或草稿位元組、寄件備份已有同一份仍再存、只補做時連了 SMTP（`SendDraftFlowTests`）；
- 第 2 項：遮蔽漏掉某一種密碼形式，或先截斷再遮蔽（`SubmitOutcomeClassificationTests`）；
- 第 7 項：`classify` 把 `ambiguous` 或不認得的錯誤分成 `not_sent`（`SubmitOutcomeClassificationTests`）；
- 說明的 caveat 被拿掉（`SendDraftToolTests`、`AppendDraftTests`）；
- 第 14 項：決策表的任何一列被改、伺服器沒宣告 `SPECIAL-USE` 時仍去問、設定的名稱只差大小寫也被接受、拒絕裡出現信匣名稱
  （`MailboxLookupTests`）；寄件備份匣等於草稿匣時仍搜尋或移除草稿（`SendDraftFlowTests`）；notes 沒有送到結果（`SendDraftToolTests`、`AppendDraftTests`）；設定檔的兩個欄位被修剪或接受空字串、控制字元（`DirectTransportConfigTests`）。`SwiftMailSession`
  對真實伺服器的部分沒有測試：能力清單裡的 `SPECIAL-USE` 是否被認出、SwiftMail 的查詢送出的是不是 `RETURN (SPECIAL-USE)`，都要 live 才驗得到；
- 第 9 項：組出的信帶 `X-Uniform-Type-Identifier`、`X-Apple-` 欄位或 multipart，或有不是 CRLF 的換行（`AppendDraftTests`）；
- 第 10 項：清單以外的參數、型別不對、顯示名收件人、主旨或 `from_name` 的控制字元、內文的 NUL 被接受，或檢查晚於開連線
  （`AppendDraftTests`）；
- 第 11 項：`classifyAppend` 把 `connectionFailed`、`timeout` 或不認得的錯誤分成 `not_appended`，或 APPEND 之前的失敗
  變成工具錯誤而不是 `not_appended`（`AppendDraftTests`）；
- 第 12 項：`unknown` 之後 APPEND 第二次、搜尋沒找到卻報成 `not_appended`、只有子字串相符的命中被當成找到、搜尋失敗被說成
  沒找到（`AppendDraftTests`，`spec-example: direct-transport / append outcomes`）；
- 第 13 項：鎖被持有時 `append_draft` 照樣開連線（`AppendDraftTests`）。

抓不到的：`SwiftMailSession` 對真實伺服器的行為（APPEND 的旗標與 `APPENDUID` 是否照預期、Mail 與其他用戶端是否把
`append_draft` 建的草稿當成可編輯的草稿、連線參數是否真的被 SwiftMail 套用、UIDPLUS 與 UIDVALIDITY 的判斷、envelope 與標頭的對照）都沒有測試，只能靠 live 測試；把
`minimumTLSVersion` 或 `certificateVerificationPolicy` 改鬆、把 keychain 改回 `SecItemUpdate`，都不會讓測試轉紅。

## 為什麼

直接傳送的價值是「不必開 Mail 也能寄」，壞掉的方式卻是安靜的：送兩次、密碼經過明文、把不確定說成沒寄出。
這些都不能靠事後補救，所以寫成不能動的清單。
