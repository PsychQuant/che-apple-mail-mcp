## Context

- 維護者 2026-11-21 的決定（#729、#742 的 Decision）：首選直接對伺服器操作；憑證另外授權、存在這個工具自己的 keychain 項目、先一個帳號；先做寄送；試點帳號 iCloud；連線用 `Cocoanetics/SwiftMail`；最低系統提高到 macOS 15。
- #716：寄件工具兩階段，寄出是對既有草稿的另一次呼叫，而且那個工具不能寫內容。
- `docs/imap-smtp-assessment.md`（#308）：APPEND 不是投遞；信封與標頭分開；寄件備份與提交是兩個階段；結果未知不重送。
- `.claude/rules/timeout-outcome-boundary.md`：只有正面觀察算證據；不得把「沒看到」報成「沒發生」。
- 已做過的驗證：加入 SwiftMail、把最低系統改成 macOS 15 之後，debug 編譯通過，`make test` 全過（1766 + 546，0 失敗）。沒有做過任何實際連線。

## Goals / Non-Goals

**Goals:**

- 寄出的位元組就是維護者看過的那封草稿，只少了 Bcc 標頭。
- 每一個結果都是觀察到的事：伺服器的最終回覆，或沒有回覆。
- 同一封草稿不會被寄兩次，包括程序在寄送途中死掉的情況。
- agent 拿不到憑證，也不能自己解除「結果未知」。

**Non-Goals:**

- 見 proposal 的 Non-Goals。另外：不修改本機的 Envelope Index 或 `.emlx`；本機要等 Mail 下次同步才會反映。

## Decisions

### 草稿的內容取自伺服器，不取自本機的 `.emlx`

#742 的 issue 原本寫「草稿內容從本機的 `.emlx` 讀」。改成取伺服器上的那一份，理由有三個：寄出之後要移除的是伺服器上的草稿，必須先認得它；伺服器的那一份是所有裝置看到的同一份；本機的草稿若還沒上傳（例如直接寫入而 Mail 沒開），伺服器上沒有東西可以移除，Mail 之後還會把它上傳成一封已經寄過的草稿。

代價：這次只能寄已經同步到伺服器的草稿。不經 Mail 把草稿放上伺服器是 #729 的階段 2。

替代方案：本機有、伺服器沒有時從本機寄。拒絕理由：寄出後留下一封會被 Mail 上傳的舊草稿，而清掉它要改本機資料庫，超出 `direct-write-transaction-safety.md` 已驗證的範圍。

### 用選擇器換成 Message-ID，再到伺服器的草稿匣找

`draft_id`（本機的 row id）只用來讀出那一列的 Message-ID；`subject_match` 直接在伺服器的草稿匣比對完全相等的主旨。兩種都必須在伺服器的草稿匣找到恰好一封。這樣不依賴 AppleScript 辨識草稿匣（`r-must-direct-db.md` 記錄過本機索引沒有草稿匣的角色欄位），也不受 `draft_id` 會漂移（#405）影響：漂移之後 Message-ID 仍然相同。

草稿匣與寄件備份匣以伺服器回報的 special-use 屬性（`\Drafts`、`\Sent`）認定；缺少或不只一個就拒絕，不猜名稱。

### 自己串四個步驟，不用 SwiftMail 的 `sendDraft`

SwiftMail 有一步到位的 `IMAPServer.sendDraft`（取信、SMTP、補存、刪草稿）。不用它，因為它任何一步失敗都只丟出錯誤，分不出 SMTP 是否已經提交：取信失敗與補存失敗都是 `IMAPError`。這個工具的重點是分階段回報，所以用它公開的零件自己串：`fetchRawMessage`、`sendRawMessage`、`append(rawMessage:)`、`store` 加 `expunge`。

代價：去掉 Bcc 標頭的程式在 SwiftMail 裡不是公開的，要自己寫一份，規則照它的（標頭行不是 CRLF 結尾、有 `Resent-Bcc`、判斷不了是不是 Bcc 欄位時拒絕，而不是照送）。

### 提交結果照 SwiftMail 的分類，對應到三種結果

| SwiftMail 回報 | 這個工具的結果 |
|---|---|
| `SMTPSendResult`（最終 2xx） | `submitted` |
| `SMTPError`（交易開始之前） | `not_sent` |
| `SMTPSendError`，acceptance 是 `notAccepted`、`rejectedTransiently` 或 `rejectedPermanently` | `not_sent`，附伺服器的回覆 |
| `SMTPSendError` 的其他 acceptance，或任何其他錯誤 | `unknown` |

`unknown` 是預設：對不上前三列的一律是 `unknown`。封閉列舉放在「確定沒寄」那一邊，因為寫錯的方向不對稱：把沒寄報成 unknown 只是多查一次，把 unknown 報成沒寄會導致重寄。

### 已寄出紀錄先寫再送

提交之前先在本機紀錄寫下這個 Message-ID（狀態 `attempting`），再開始 SMTP。程序在途中死掉時，下次看到 `attempting` 就當作 `unknown`。`submitted` 與 `unknown` 的紀錄都會擋住同一個 Message-ID 的再次提交；`not_sent` 會把紀錄清掉。

`unknown` 只能由維護者用命令列清除（`--direct-transport-forget <message-id>`），不提供 MCP 工具：要不要重寄是人的決定，agent 不能自己解除。

紀錄是一個 JSON 檔，放在 server 的狀態目錄，權限 0600，以暫存檔加改名的方式寫入。只記 Message-ID、帳號 id、狀態、各階段的狀態、時間與伺服器的最終回覆；不記主旨、收件人或內文。

### 提交之後的兩個階段各自回報，可以補做

提交成功之後：補存寄件備份（設定是 `append` 時），再移除草稿。任何一個失敗，結果仍是 `submitted`，並點名哪個階段待補。同一封草稿再呼叫一次 `send_draft` 時，紀錄顯示已提交，就只做待補的階段，不再提交。

寄件備份是否需要自己補存，由設定檔的 `sent_copy` 決定（`append` 或 `provider`）。iCloud 會不會自動保存，沒有查到文件，要在試點時觀察；在那之前設定檔必須明寫，不給預設值。

### 憑證只走 keychain，設定走檔案

- 設定檔 `direct-transport.json` 放在 server 的狀態目錄，封閉的欄位：`account_id`、`address`、`smtp`（`host`、`port`）、`imap`（`host`、`port`）、`sent_copy`、`allowed_from`。裡面沒有密碼。檔案不存在就是沒有設定；讀不懂就拒絕並說明，不當成沒有設定。
- 密碼存在 keychain 的 generic password，service 固定為 `che-apple-mail-mcp.direct-transport`，account 是設定檔的 `address`。由 binary 的命令列模式 `--direct-transport-set-credential <address>` 從 stdin 讀入並建立項目，所以建立者就是這個 binary，之後讀取不會跳授權視窗。
- 密碼不出現在 MCP 參數、工具結果、stderr、log、設定檔或版本控制裡。

替代方案：讀 Mail 存在 keychain 的密碼。拒絕理由見 `docs/imap-smtp-assessment.md`：Mail 已登入不代表另一個 binary 可以重用它的憑證。

### `send_draft` 拒絕清單以外的參數

其他工具會忽略不認得的參數，拼錯的旗標因此安靜地失效（#677）。`send_draft` 的參數是封閉的：`account_name`、`account_id`、`draft_id`、`subject_match`。出現其他參數就拒絕，包括 `body`、`to`、`attachments`，這樣「這個工具不能寫內容」是可以檢查的。

### 相依的釘法與 `Package.resolved`

SwiftMail 自己把 `swift-nio-imap` 釘在一個 commit，SwiftPM 不接受以版本號相依這樣的套件，所以以 1.17.0 那個 tag 的 commit 相依。相依樹從 7 個變成 24 個，而 `Package.resolved` 目前被 `.gitignore` 排除，等於每次編譯都可能拿到不同的版本。把它納入版本控制，讓出貨的 binary 可以重建。

### 分兩個 PR

1. 最低系統、相依、`Package.resolved`、文件裡的系統需求：不改任何行為，風險在編譯與既有測試，已經試過。
2. `direct-transport` 與 `send_draft`。

先合第一個，避免它與其他分支長期衝突。

## Risks / Trade-offs

- [沒有對真的伺服器跑過] → 工具描述寫明「尚未對真的伺服器執行」；issue 保持開啟並貼 `blocked-on-setup`，直到維護者設好憑證、同意後跑過只寄給自己的測試（`deferred-live-verification.md`）。
- [SwiftMail 的行為與這裡的假設不同] → 連線層藏在一個協定後面，測試用替身走每一個分支；實際連線時逐項核對。
- [本機與伺服器不一致] → 結果寫明本機索引要等 Mail 同步；這個工具不改本機資料。
- [最低系統提高] → macOS 13、14 的使用者停在 v4；寫進 CHANGELOG 的 BREAKING。
- [binary 變大、編譯變久] → release 編譯的數字記在 issue 上。
- [部署目標改變換了 Foundation 行為（#538、#561）] → 完整測試已在新目標下通過（debug）；release 的 binary 另外啟動檢查。
- [寄件身分] → From 必須在 `allowed_from` 或等於 `address`，否則拒絕。

## Open Questions

- iCloud 是否自動保存 SMTP 提交的信到寄件備份匣（決定 `sent_copy` 的建議值）。
- iCloud 的 IMAP 是否回報 `\Drafts`／`\Sent`，以及是否支援 `UIDPLUS`（決定刪草稿能不能只刪那一封）。不支援時拒絕刪除、把草稿移除列為待補，不用會波及其他信的 `EXPUNGE`。
