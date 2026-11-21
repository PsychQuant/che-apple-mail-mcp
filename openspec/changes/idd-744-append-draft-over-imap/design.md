## Context

- #729 的 Decision：首選直接對伺服器操作；先一個帳號試點。#742 的 Decision：這是「Apple Mail 的 MCP」，不一定經過 Mail 這個 App，但每個工具要讓人看得出走哪條路徑。
- 階段 1（#742）已有：設定檔、keychain 憑證、TLS 規則、SwiftMail 連線、`\Drafts` 的辨識、提交鎖、遮蔽。
- SwiftMail 1.17.0：`IMAPServer.append(rawMessage:to:flags:internalDate:)` 回傳 `AppendResult`（伺服器支援 UIDPLUS 時有 UIDVALIDITY 與 UID）。APPEND 的錯誤：伺服器的 tagged NO／BAD 回成 `IMAPError.commandFailed`（`AppendHandler`），超過伺服器宣告的大小上限在送出前丟 `appendLimitExceeded`，連線關閉是 `connectionFailed`，逾時是 `timeout`。
- #745 的唯讀比對（Mail 16.0）：Mail 寄出的純文字信是單一 `text/plain`；Mail 存的草稿是 `multipart/alternative`、純文字段空白、帶草稿專用標頭。
- 沒有做過任何實際連線。

## Goals / Non-Goals

**Goals:**

- 建草稿不需要 Mail 在執行；結果只陳述觀察到的事。
- 這封草稿交給 `send_draft` 原樣送出時，收件人收到的是 Mail 寄純文字信的結構。
- 重複建立只會多一封草稿，不會寄出任何東西。

**Non-Goals:**

- 見 proposal。另外：不修改本機的 Envelope Index 或 `.emlx`；本機要等 Mail 下次同步才看得到。

## Decisions

### 獨立的新工具，不是 `create_draft` 的另一條路徑

`create_draft` 現在有 GUI 與 opt-in 直接寫入兩條路徑，不符條件會退回 GUI。直接傳送的工具不符條件就拒絕、不退回（#742 第 1 項保證），兩種行為放在同一個工具裡，呼叫端無法從工具名稱看出會發生什麼。

替代方案：`create_draft` 加 `transport: "imap"`。拒絕理由：同一個工具一部分參數走 Mail、一部分不走，結果與權限需求各不相同，說明會難讀，也違反「每個工具要讓人看得出走哪條路徑」。

### 內容由工具自己組，單一 `text/plain`

不沿用 `DirectDraft.buildMessage`（Mail 草稿的版面）。那個版面是為了讓 Mail 把直接寫入本機的列認成自己的草稿；這裡的草稿會被 `send_draft` 原樣送出，Mail 草稿的空純文字段與草稿標頭會送到收件人手上（#745）。單一 `text/plain; charset=utf-8`、CRLF；ASCII 且每行不超過 998 octets 用 `7bit`，否則 `base64`（每行 76）。標頭的編碼與摺行沿用 `DirectDraft` 的 helper（RFC 2047、不拆位址的摺行），換行一律轉成 CRLF。

代價：在 Mail 裡打開這封草稿時，樣子可能與 Mail 自己建的草稿不同；這要等 live 測試才知道。

### 只收純位址，文法寫死

顯示名要處理引號、逗號與 RFC 2047，`send_draft` 的位址檢查也還沒有對顯示名做過完整的 live 驗證。第一版只收純位址，而且是 RFC 5321 的一個子集：dot-atom 的 local part（不超過 64 octets）、`@`、至少兩段的網域（每段 1–63 個字母、數字、連字號，不以連字號開頭或結尾），全長不超過 254 octets。不收 quoted local part、網域 literal、非 ASCII。寄件人的顯示名用 `from_name`，位址一律是帳號的位址。

verify 第 1 輪指出先前的規則會收 `a@.example.com` 與過長的 local part；IMAP 存得進去的位址，SMTP 不一定能用。

### 大小上限，組信在取得鎖與憑證之後

內文 5,000,000 octets、主旨 2,000、`from_name` 200、收件人合計 100，在讀設定之前檢查。組信會複製內文好幾次，所以放在取得鎖與讀到憑證之後：被拒絕的呼叫不為一大段內文付成本（verify 第 2 輪）。

### 三種結果，`unknown` 只看正面觀察

`commandFailed` 與 `appendLimitExceeded` 算 `not_appended`。依據是釘住版本的 SwiftMail：失敗的指令不會重送（`IMAPConnection+CommandExecution.swift` 的 `runCommandHandler` 直接丟出錯誤）；`commandFailed` 只會來自 APPEND 的 tagged NO／BAD（`AppendHandler`）或送出前的重新登入（`IMAPServer.executeCommand`）；`appendLimitExceeded` 在送出前丟出。這三種都表示草稿沒存。APPEND 之前的連線、登入、找草稿匣失敗也是 `not_appended`（verify 第 1 輪）。其餘（APPEND 送出後的連線關閉、逾時、不認得的錯誤）都是 `unknown`。

`unknown` 之後嘗試一次以 Message-ID 搜尋草稿匣。session 沒有「連線是否還在」的訊號；SwiftMail 預設在指令前發現連線斷了會重連並重新登入，所以搜尋可能在新的連線上成功，也可能失敗。結果：恰好一封改報 `appended` 並給 UID；多於一封改報 `appended` 但不給 UID；搜尋失敗回報「沒能搜尋」，搜尋沒找到回報「沒看到不是沒存」，兩者都仍是 `unknown`（`timeout-outcome-boundary.md`）。命中要逐字比對 Message-ID，因為 IMAP 的標頭搜尋是子字串比對。

一律不再 APPEND：伺服器可能已經存了，再 APPEND 一次就是兩封。

結果裡的每一段文字在工具邊界再遮蔽一次密碼，不依賴各個錯誤來源自己遮蔽（verify 第 2 輪）。

### 沒有去重紀錄，但共用提交鎖

每次呼叫都是新的 Message-ID，所以「同一封送兩次」在這裡的形狀是「多一封草稿」，不會寄出任何東西；結果與說明寫明再呼叫一次會多一封。提交鎖沿用 `send_draft` 的那一把，讓兩個直接傳送的呼叫不同時開連線，`--direct-transport-forget` 也不會在 append 進行中改紀錄。

### `send_draft` 以 Message-ID 選草稿

`draft_id` 要讀本機列，Mail 沒開時 `append_draft` 建的草稿沒有本機列；`subject_match` 在主旨相同時會拒絕。`message_id` 先正規化成 `<local@domain>`（只收 printable ASCII），再走 `draft_id` 同一條比對：以去掉角括號的形式搜尋，每個命中逐字比對。本機列根本不讀。

## Risks / Trade-offs

- [伺服器對 APPEND 的處理不同] → 試點只有一個帳號；結論不推到其他帳號類型。
- [Mail 不把單一 `text/plain` 的草稿當成可編輯的草稿] → live 測試要在 Mail 與另一個用戶端各打開一次；在記錄之前工具說明保留「NOT YET RUN AGAINST A REAL MAIL SERVER」。
- [標頭注入] → 主旨、`from_name` 的控制字元與位址裡的結構字元在開連線前拒絕。
- [`commandFailed` 的範圍隨 SwiftMail 版本改變] → 分類的註解寫明依據的檔案；升級釘住的版本前要重讀。
