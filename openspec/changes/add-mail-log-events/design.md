## Context

#463 的 spike 證明：Mail 存草稿、建立上傳佇列、通知同步引擎、收到 IMAP 上傳回條，這整條鏈都會寫進 Mail 行程的 unified log（subsystem `com.apple.mail`、`com.apple.email`）。目前 MCP 沒有任何讀日誌的能力，所以「為什麼沒同步」只能由人在終端機手動對照兩個時間窗口。

#465 的 Decision comments 已定案：範圍是任何 Mail 事件、用途是找斷點；需要原始日誌行並分簡短／詳細兩種設定；詳細模式原樣回傳並標示敏感，選用的 `redact_identifiers` 預設關閉；維持 `log show`。

診斷與討論階段的實測（macOS 27.2、Mail 16.0）：

- 讀取日誌只要使用者在 `admin` 群組；Developer ID 簽章加 hardened runtime 加現有 `Entitlements.plist` 下，`/usr/bin/log` 與 `OSLogStore` 都讀得到，沒有 TCC 提示。
- 10 分鐘窗口約 15 至 16 千行、17 至 18 MB、2 至 3 秒；60 分鐘約 78 千行、90 MB、5 秒。
- ndjson 每行有 29 個欄位，其中 `formatString` 在約 99.99% 的行都有，是程式裡的靜態字串，不含執行期資料。
- 每行開頭的 `%@` 是「帳號名稱加信箱名稱」，有些還夾著物件記憶體位址；10 分鐘內約 28% 的事件含 email 形狀字串。
- 單一 category（`IMAPSyncActivity`）15 分鐘內有 43 種不同的 `formatString`。
- IMAP 上傳完成的回條（`APPENDUID`）所在行的 `formatString` 只有 `%{public}@`，整行都是參數。
- 「沒有日誌行」不代表沒發生：以 10 分鐘為窗口，12、18、24 小時前是 0 筆，48 小時前又有 20,069 筆。

## Goals / Non-Goals

**Goals:**

- 一個唯讀工具，能查任何 Mail 事件，用來比對事件鏈、找出斷點。
- 簡短模式不輸出帳號、主旨、收件人、Message-ID、document UUID——前提是 `formatString` 是編譯期字串（Mail 自己的模板都是）；看起來像資料的模板另有後備檢查，但那不是保證。
- 詳細模式提供原始行，並誠實標示它含有識別資訊。
- 輸出量、執行時間都有上限；任何查不到或讀不到的情況回 `unavailable` 或 `no_events_in_window`，永遠不斷言「沒發生」。

**Non-Goals:**

- 不做全面的事件分類表、不做斷鏈偵測或雙窗口自動比對。
- 不讀寫 Mail 資料庫；日誌是觀察通道，不是狀態來源。
- 不保證 Mail 16.0／macOS 27.2 以外的版本；格式是私有的，解析不出就誠實降級。
- 不提供「從日誌推斷某動作沒做」的任何欄位或語意。

## Decisions

### 單一工具以 detail 參數切換簡短與詳細

一個工具 `get_mail_log_events`，`detail` 為 `brief`（預設）或 `detailed`。先例是 `search_emails` 的 `projection` 參數。**替代方案**：拆成兩個工具，好處是 MCP client 若逐工具核准可以分開管；代價是兩份 description、兩份測試。使用者在討論時沒有選拆分，若日後發現 client 確實逐工具核准，再拆是加法，不破壞既有呼叫。

### 以 log show 子行程讀取 unified log

以 `Process` spawn `/usr/bin/log show --style ndjson`，逐行讀取，達到上限就終止子行程並回收；沿用 `MailController` 已有的子行程紀律（絕對路徑、不經 shell、關閉 stdin、並行排空 stderr），並多一條：讀取迴圈自己強制 deadline，不依賴子行程關閉管線（孫行程握著管線時 EOF 永遠不會來，#301 的前例）。

**決定性理由（實測，2026-10-02，macOS 27.2、固定的 60 分鐘窗口、約 63,300 筆事件）：記憶體隔離。** 在常駐的 MCP 伺服器行程內讀 `OSLogStore`，每次呼叫增加約 230 MB 且沒有歸還（連續三次讀取：5 → 255 → 486 → 716 MB，最後一次讀完 2 秒後仍是 716 MB；只量了三次，是否在更多次後持平未測）。`log show` 的尖峰在子行程：提早中止 350 MB、窄窗口（10 分鐘、3 個 category）237 MB，行程結束即歸還給系統。伺服器可能連續執行好幾天，這個差別會累積。

**替代方案 `OSLogStore.local()`** 的優點是真的：較快（第一筆 0.43 秒對 1.04 秒；讀完整個窗口兩者都約 5 秒）、欄位有型別、不用解析文字，也能提早停止（讀 1000 筆總共 0.47 秒對 1.06 秒）。討論階段我提出的另外兩個理由**經量測不成立，已撤回**：（a）「`OSLogEntryLog` 不能在測試中造假資料」是錯的，它可以建構也可以子類別覆寫；（b）「`OSLogStore` 沒有同等的取消手段」是錯的，迴圈 break 即可。先前「兩條路徑筆數差 4 至 5%」是拿不同時間點的即時窗口比較造成的假象：在固定窗口內 `OSLogStore` 與 `log show --info` 都是 63,310 筆，預設的 `log show` 只少 7 筆 info 層級（0.011%），所以本工具回報的是預設層級（Default 以上）事件。

**這個決定仍然可逆**：兩條路徑共用 `LogEventSource` 介面。若日後量到 `OSLogStore` 的記憶體在更多次呼叫後持平，可以改用它，切換只動實作。

### 簡短模式以 formatString 作為事件名稱

簡短模式的事件名稱就是 `formatString`（程式裡的靜態字串），不是手寫的分類表。數字參數的抽法是把 `formatString` 切成「字面文字／整數佔位符／其他佔位符」的序列，依序比對訊息，**線性時間**：字面要逐字相符；整數佔位符吃一段可帶負號的十進位數字，或 `<private>`（對應 `null`）；其他佔位符（萬用段）的內容可以由別人決定，所以模板在萬用段處切成幾段，每段用一個萬用段內容推不動的錨點定位：**開頭段**從訊息起點往後比；**尾段**（最後一個萬用段之後）必須剛好吃到訊息結尾，而且只能有一個起點做得到；**中段**（兩個萬用段之間）沒有錨點，帶整數的中段必須在那段範圍裡只出現一次，不帶整數的只要出現就好。整數緊貼萬用段（`abc12` 是 12 還是 2？）沒有界線，判 `unstructured`。任一條件不成立，就不輸出任何參數並標 `unstructured`。

為什麼不用一條正規表示式：第一版的設計是把模板轉成 `(.*?)…(.*?)` 的錨定正規表示式，但訊息有一部分來自郵件內容（主旨可能落進 `%@`），多個 `.*?` 對不符合的長訊息是多項式回溯，惡意主旨可以拖住伺服器。為什麼要求唯一：佔位符的內容可以由遠端決定（帳號名稱、共享資料夾名稱），「第一次出現」可能就在它裡面，接下來讀到的整數是被植入的（verify round 1 finding #35 以 `[acct - evil count 99999 items x] count 3 items done` 重現）。寧可不說，也不報錯的數字。

**為什麼 round 2 改成分段**：round 1 的規則要求「**每個**萬用段後面那段字面都唯一」，連模板自己重複用的分隔符也算進去，於是 `%{public}@ %lu messages expunged` 只要帳號括號裡有空格就整筆丟掉整數（verify round 2 finding 6）。8 小時真實日誌 382,806 筆裡，模板帶整數的 115,966 筆：舊規則抽到 104,919 筆、新規則抽到 112,028 筆；兩者都抽到的 250,138 筆事件**整數逐筆一致、0 筆不同**，只有 47 筆（`…Exists changed to %lu%s`，整數緊貼 `%s`）是新規則刻意不報。剩下 3,938 筆抽不到的，主要是日誌系統修剪了訊息結尾的空白，訊息本來就對不上模板。

**備援**：「簡短模式不含資料」依賴 `formatString` 是編譯期字串這個觀察。若某段程式把執行期字串當格式記錄，資料會出現在模板裡，所以模板在把佔位符換成中性記號、並把 `佔位符@佔位符` 收成一個之後，若仍含 email 形狀或 UUID 形狀，就輸出 `<template withheld>`（`<%{public}@@%{public}@>` 是「這裡印 Message-ID」的模板，不含資料，不會被擋）；超過 1,024 字元的模板不掃描、直接擋下（實測最長的真實模板 351 字元），這也替所有正規表示式設了上界（finding 3／17／20：備援的 email 形狀少了遮蔽那邊的後顧斷言，對長字串是平方級；現在兩邊共用同一個 pattern）。這是**後備**，不是保證：它只認得 email 與 UUID 形狀。

**替代方案**：手寫事件對照表（白話名稱）——實測單一 category 就有 43 種 `formatString`，全面維護綁在私有格式上，成本高於價值。人類可讀的標籤日後可以作為選用對照表加上，查不到就顯示 `formatString`。

### 白名單只收 APPENDUID 回條

`IMAPConnection` category 的上傳完成回條，其 `formatString` 只有 `%{public}@`，簡短模式否則只能顯示「無結構」，而它正是 #463 找斷點最需要的事件。v1 加一個只含一項的**封閉白名單**，簡短模式輸出 `kind: "known"`、`event: "imap.append_uid_received"`、`args: []`，**不帶任何訊息內容**。不得依性質相似類推第二項；新增第二項需要另一個 change。

辨識條件有三層，每一層都是被實際反例逼出來的：

1. **形狀是 Mail 實際記下的** `[APPENDUID (n, n…)]`（數字之間是逗號與換行，括號內只能有數字、逗號、空白），不是 RFC 3501 的線上格式 `[APPENDUID n n]`。第一版照 RFC 寫、對照合成 fixture 全部通過，卻在真實日誌裡什麼都找不到（實跑簽章後的 binary 才發現）。RFC 形式從未在日誌裡觀察到，所以不辨識。
2. **不是只看 `APPENDUID` 這個字**：IMAP 的 FETCH 回應會把郵件內容（例如主旨）寫進同一個 category。
3. **錨定在這一行自己的 `Read: `**：訊息開頭的那個，或緊接在 Mail 連線標頭 `[伺服器] <連線 id:[Mailbox name=…]> ` 之後的那個；其後的 tag 不能以 `*` 開頭，接著是 `OK ` 與回應碼。只看形狀還不夠：主旨可以包含完整的 `[APPENDUID (1, 2)]`（verify round 1 finding #2）。round 1 錨定在「整則訊息裡的第一個 `Read: `」，但 Write 行會回顯 Mail 送出去的內容，APPEND 的字面可以引用一封收到的信，裡面的 `Read: 1 OK [APPENDUID …]` 就成了第一個（verify round 2 finding 7）。標頭結束於第一個 `]> `，不是第一個 `>`：真實信箱名稱含 `<`、`>`（8 小時 88,636 筆 Read 行中 653 筆）。round 3 再收緊（finding 4／6）：tag 必須是數字與點（最多 16 字元），回條之後到訊息結尾只能是空白——**回條就是 Mail 讀到的整塊**。FETCH 的字面若被切成好幾次讀取，後面那塊會以寄件人的位元組開頭，只錨定開頭擋不住。log store 40 小時內全部 27 筆真實回條：tag 都是 `n.n`、`)]` 之後都沒有任何字元、都在塊首、沒有一筆排在未標記回應之後，收緊後的規則 27/27 認得。代價：Mail 若把回條和前面的未標記回應記在同一塊，回條會漏認（`unstructured`，不會誤認），27 筆中觀察到 0 筆。殘留：一整塊恰好只含偽造回條文字（起點與終點都要對齊讀取邊界）。已知限制（round 4 finding 10）：伺服器若在回應碼後面加文字，回條會漏認（不會誤認）。證據可重跑（round 4 finding 20）：`scripts/mail-log-live-check.py` 的回條普查逐筆以該毫秒查詢 log store 內的每一筆回條。殘留風險：標頭裡的信箱名稱由資料夾擁有者命名，不是任意寄件人。

這個工具的用途正是用回條判斷上傳有沒有發生，偽造的回條會造成錯誤的安心感，所以寧可漏認，不可誤認。**替代方案**：把整行當詳細才給——那簡短模式就看不到上傳回條，無法回答 #463 的核心問題。

### 帳號以回應內代號區分

簡短模式丟掉 `%@` 後分不出帳號。做法：**只有**以 `[帳號 - 信箱]` 開頭的訊息才取帳號鍵（`[` 到第一個 ` - `），依首次出現順序在**單一回應內**指派 `A`、`B`、`C`……（之後 `AA`、`AB`）；帳號鍵本身從不輸出；其他情況 `account: null`。代號跨呼叫不穩定，`accounts_seen` 只計回傳事件中的代號。

為什麼限定 ` - ` 形式：第一版把任何 `[…]` 前綴都當帳號，但 `IMAPConnection` 這類連線層 category 的前綴是伺服器／連線名稱（`[Fixture.Server]`），同步層才是 `[帳號 - 信箱]`。結果同一個帳號在不同 category 拿到不同字母（verify round 1 finding #13，reviewer 的真實樣本：12 個 category 有 15 個不同的鍵，只有 6 個含 `@`），在 #463 的事件鏈裡「通知引擎」與「上傳回條」可能拿到不同字母，呼叫端很可能讀成「回條來自另一個帳號」而誤判斷點。所以代號只在 `[帳號 - 信箱]` 形式的訊息之間可比。

round 2 再收緊一層（finding 18）：括號必須是**模板**放在開頭的，只有兩種形狀——模板以萬用段開頭且有自己的字面（`%@ Received %lu …`），或模板本身以 `[`、萬用段、` - ` 開頭（`[%{public}@ - %{public}@] Reset mailbox in sync state`）。只有佔位符的模板（`%{public}@`）整則訊息都是執行期文字，若照樣給代號，能把 `[猜測 - x]` 送進日誌的人可以從「字母相不相同」得知猜測是否為真實帳號名。8 小時真實日誌：新舊規則給代號的事件數同為 122,853、帳號數同為 8，沒有損失。代價（finding 25，round 3 實測更正）：連線層的行（包括上傳回條）沒有代號，所以**簡短模式無法把回條對到帳號**——round 2 寫的「靠 activity 對照」不成立：27 筆真實回條中 19 筆的 activity id 是 0。詳細模式的連線標頭會顯示伺服器與信箱。殘留（round 3 finding 16）：第一種形狀信任模板開頭的萬用段就是帳號括號；若某個這樣的模板在那裡放的不是帳號，字母相等就成了對那段文字前綴的相等性探測。實測 8 小時中這兩種形狀給出的帳號數等於實際帳號數（8），帳號鍵從不輸出。**替代方案**：輸出帳號名稱——違反簡短模式的保證。

### 窗口、筆數上限與由早到晚的分頁

時間窗口三選一：`last_minutes`（1 至 60，未給任何窗口時預設 10）、`since` 加選用的 `until`、`around` 加選用的 `radius_seconds`（1 至 1800，預設 60）；窗口跨度上限 60 分鐘。事件固定**由早到晚**排序。

**游標**（verify round 2 後的版本）是**位置**，不是時間：`(next_start, next_offset)` = 「最後一筆回傳事件之後」——那筆事件的毫秒，加上呼叫端在那個毫秒已拿到幾筆相符事件。續查方式：`since=next_start`、`offset=next_offset`、`until=` 上一頁的 `window.end`；服務在 `since` 那個毫秒跳過前 `offset` 筆相符事件（依讀取順序，同毫秒的事件在回應裡保持這個順序）。

為什麼一定要有位移：真實日誌單一 category 的同一毫秒最多 169 筆事件，只有時間的游標指不進這樣一群。round 1 的「第一筆沒回傳的事件」在 `limit` = 1 時卡死；round 1 修正版改成「不切開同時間戳的一群、必要時超過 `limit`」，但 `size_cap` 仍會切開，切在群組中間時游標指向已回傳過的事件，群組大於 64 KiB 時每次都回同一頁（verify round 2 findings 1／2／4／19，Codex 與 logic lens 各自獨立報出）。有了位移，所有停止原因都從停下的地方接續：

- `limit`／`size_cap`：最後一筆回傳事件之後。讀取在讀到 `limit + 1` 筆相符事件時停止（那一筆證明還有更多）；一頁不超過 `limit`。
- `scan_cap`／`deadline`：讀到的相符事件全部回傳了，所以游標推進到**掃描前緣**（讀過的窗口內事件中最晚的時間，不論是否符合 `contains`），位移是那個毫秒已回傳的相符事件數。否則 `contains` 搜尋停下後，續查只會重掃同一段。
- 沒讀到任何超過游標的窗口內事件就停下 → `unavailable`（`deadline_exceeded`／`scan_cap_exceeded`），不回一個會把呼叫端帶回原地的游標。

**到達順序**：提前停止依賴「到達順序＝時間順序」（macOS 27.2 實測 165,748 筆 0 次倒退）。round 2 加了偵測（finding 23／27）：讀到比先前更早的事件後就不再提前停止、讀完再排序，`notice` 說明倒序筆數；游標放在「最後回傳之後」而不是「第一筆沒回傳的」，所以停止後才遲到的較晚事件仍會被下一頁撿到。剩下的假設只有：停止之後才遲到、而且比游標更早的事件，無法偵測。round 3（finding 2）：讀取中出現過倒序時，`scan_cap`／`deadline` 的游標不再跳到掃描前緣（它可能越過一筆稍後才到的相符事件），改放在最後回傳之後；一筆都沒回傳時仍用前緣，否則沒有進度。所以「每筆恰好一次」的前提是**讀取順序等於時間順序**，description、spec、CHANGELOG 都這樣寫，不再寫成無條件保證（finding 8／12）。

`log show` 只收整秒，runner 把窗口擴到整秒：起點向下取整，終點**一律推到下一個整秒**（round 3 finding 3／5／11：`--start T --end T` 實測回 0 筆，而終點落在整秒時那一秒會被排除，閉區間窗口在 T.000 的事件就讀不到）；回應宣告的是**精確窗口**，服務會丟掉窗口外的事件（兩端含），且不計入 `limit`。回應序列化後超過 **65,536 位元組**時從尾端丟棄事件直到放得下（至少保留一筆，游標才會前進），`stopped_by: "size_cap"`：Claude Code 在 MCP 輸出超過 10,000 tokens 時警告、超過 25,000 tokens 時把結果存成檔案只留路徑（code.claude.com/docs/en/mcp），第一版的 262,144 位元組約 65–90k tokens，遠超過。64 KiB 是位元組上限、不是 token 保證（finding 21）：ASCII 的 JSON 約 15,000 至 22,000 tokens，帶中日韓文字的詳細輸出會更多，超過 25,000 時由 Claude Code 存成檔案。**替代方案**：回傳最晚的 N 筆——日誌 CLI 無法反向輸出，必須讀完全部再丟棄，成本高且無法提早停止。

### 誠實的未知與涵蓋範圍

回應有三種狀態：`ok`、`no_events_in_window`、`unavailable`。沒有任何欄位或值斷言「沒發生」。`no_events_in_window` 附固定的說明：日誌沒有相符行不代表動作沒有發生（Mail 當時可能沒在執行，或該 category 被遮蔽）；若同時是提早停止，再加一句「這個窗口沒有查完」。回應固定包含實際查詢的窗口、回傳事件的最早與最晚時間、`source`，以及 `stopped_by`。

`unavailable` 只有五種 `reason`，附最多 300 字元的 `reason_detail`（工具自己的說明或 `log` 的 stderr 尾端，不含日誌內容）：`spawn_failed`、`nonzero_exit`、`unrecognized_output`、`deadline_exceeded`、`scan_cap_exceeded`。`unrecognized_output` 是 verify round 1 加的（finding #7／#10）：Apple 若改了時間戳的欄位名，每一行都會變成「不是事件」，第一版會靜靜回報一個乾淨的空窗口——正是這個工具最不能說的那句話。現在：沒有時間戳的 JSON 物件除了 `log show` 的收尾 `{"count":N,"finished":1}` 以外都計入 `skipped_lines`，一筆事件都讀不懂時回 `unrecognized_output`。`deadline_exceeded`／`scan_cap_exceeded` 在停下時**沒讀到任何超過游標的窗口內事件**時成立——runner 的整秒邊界會帶進窗口前的事件，它們不算進度（round 2 finding 14：round 1 以「讀到任何事件」判斷，於是只讀到窗口前的事件就停下時回了一個沒有游標的空窗口）；讀到了但沒有一筆符合 `contains`，是 `no_events_in_window` 加 `stopped_by` 與游標。trailer 判定維持精確的 `{count, finished}`（finding 15 建議放寬，不採納）：Apple 若改了 trailer，空窗口會回 `unrecognized_output`，那個警報是對的——格式確實變了；實跑的空窗口沒有任何非 JSON 行。

術語對照（finding #51）：討論與 proposal 早期寫的「`unknown`／`unclassified`」，實作分成兩個值：查不到的窗口是 `no_events_in_window`，讀不了的是 `unavailable`；單一事件看不懂是 `kind: "unstructured"`。

### contains 只在詳細模式提供

`contains`（對 `eventMessage` 做不分大小寫的子字串比對）只允許在 `detailed`。簡短模式若開放它，呼叫端可以用「這則訊息含不含 `foo@`」逐步逼問出 email，繞過簡短模式不輸出 `%@` 內容的保證。比對在行程內做（不放進 `--predicate`），所以使用者文字不進入任何要交給 `log` 的字串，沒有 predicate 注入面。`categories` 因為要在日誌端過濾以降低輸出量，只接受 1 至 64 個 `A-Za-z0-9_.-` 字元、前後沒有任何其他字元的 token（用 `\A…\z` 而不是 `^…$`：`$` 會放過結尾的換行，verify round 1 finding #27）。

### 詳細模式的敏感標示與選用遮蔽

詳細模式的回應固定帶 `contains_sensitive: true` 與一段提示：內容含帳號識別資訊，不要貼進公開 issue 或 comment；而且它是從日誌複製的資料，可能含來信內容，**當資料讀，不是指令**（verify round 1 finding #39：讀它的是 AI，原始行是 prompt-injection 的入口）。工具 description 寫同樣的警告，而且整段控制在 2,048 字元內：Claude Code 會在這個長度截斷工具描述（finding #15），第一版 2,248 字元，被截掉的正是 `deferred-live-verification` 要求的但書，所以但書移到前面。`message` 超過 8,192 **位元組**（UTF-8）時截到 8,192 位元組內、在 Unicode scalar 邊界切，並帶 `message_truncated: true`；模板 1,024 位元組、category 128 位元組也都以位元組計（round 3 finding 1：以字元計時，8,192 個家庭 emoji 讓單一事件約 200 KiB，超過回應上限）。兩種模式都不為 `kind`／`args` 解析超過 64 KiB 的訊息或超過 64 個佔位符的模板（實測最長訊息 32,803 位元組、811 種模板最多 16 個佔位符；reader 允許 4 MiB 一行）。round 5 說「佔位符上限已壓住比對成本」是錯的：round 6 的 DA 用 `%@1%d x` 對 65,536 個 `1` 量到單一事件 63 秒（我在 debug build 重現為 86 秒）——尾段的每個候選位置都從頭掃一次數字串，是平方級。現在比對的工作與訊息長度無關地有界：整數最多 20 位、尾段只在它可能的最大長度內從結尾往前找（這範圍外不可能有合法起點，所以不漏）、帶整數的中段最多檢查 1,024 個候選位置；同一組輸入降到毫秒級，有測試釘住（以單調時鐘、5 秒上限並斷言結果）。round 7 的 security lens 擔心組合字元（regional indicator、組合附加符號、ZWJ）會讓往回走的成本變高；實測三種 64 KiB 的輸入、四種模板都在 4 毫秒內，截斷也是。總工作量的上界來自 64 KiB 的解析上限，每個候選位置的工作與候選數量則各自有上限；帳號括號必須在訊息前 1 KiB 內收尾（round 4 finding 19）；subsystem、category、process 超過 128 位元組都隱藏（round 4 finding 7／13／18）。

選用的 `redact_identifiers`（預設 `false`，只在詳細模式有效）把 email 形狀、UUID 形狀、角括號 Message-ID 形狀換成 `<email-N>`、`<uuid-N>`、`<message-id-N>`（N 在單一回應內穩定）。**截斷在原文上做、而且不切開 token**（round 4 finding 1–6、9、12、17）：原文先截到 8,192 位元組內，再退到最後一個**安全切點**：空白之後、`<` 之前或 `>` 之後；一個都沒有就整段不回傳。email、UUID、Message-ID 都跨不過這三種位置（round 6 再修兩處：cap 之後原文的下一個字元也算，`<` 剛好在 cap 外時整段 prefix 就是安全的；空白只算 `CharacterSet` 與 ICU `\s` 都承認的——實測 VT、NEL 兩邊都算，U+200B 只有 `CharacterSet` 算，它能出現在 Message-ID 裡，所以不是切點），所以截斷處不會留下任何識別字的片段（round 5 finding 1／5／8／16：round 4 的規則退滿 1,024 位元組還找不到空白就停下，長 token 的開頭會被回傳）；接著只對這段做遮蔽，遮蔽編號只用在回傳的識別字上；`contains` 比對的就是同一段（遮蔽時用不帶編號的 `<email>`）。round 3 的做法是「先在 16,384 位元組的工作前綴上遮蔽再截」，兩次截斷各用不同長度的遮罩，於是 `contains` 看得到回傳之外約 10 位元組，工作前綴的邊界也會切出半個地址；兩者都已用測試重現後修掉。遮罩會讓回傳的文字略長於 8,192 位元組（最壞約 3 倍，例如 `<a@b>` → `<message-id-12>`）。單一事件的上限由各欄位的位元組上限保證：所有欄位同時處在最壞情況時約 60 KB，有測試釘住。round 4 加的「縮減訊息」後備路徑因此走不到，而且一旦走到會讓 `contains` 看見不回傳的文字（round 5 finding 4／12／20），已移除。開啟遮蔽時，`contains` 比對的是**遮蔽後**的文字（三種形狀換成不帶編號的 `<email>`、`<uuid>`、`<message-id>`），否則呼叫端可以用 `contains: "alice@"` 命中與否逼問出被遮蔽的內容（verify round 2 finding 24）。回應的 `redaction` 欄位明講這是**盡力而為，不是隱私保證**：帳號顯示名稱、信箱名稱等不符合這三種形狀的字串不會被遮蔽。email 形狀的比對加了後顧斷言，只從一段連續字元的開頭開始比——沒有它時，一則 8192 字元的訊息要 5 秒（verify round 1 finding #26 實測）。

### 時間參數必須帶時區偏移

使用者在臺北，裸時間字串很容易被當成別的時區。`since`、`until`、`around` 一律要求 ISO 8601 且帶明確偏移（或 `Z`），不帶的拒絕並在錯誤訊息說明格式；日曆上不存在的日期時間（`2026-02-30`、`24:00:00`）也拒絕，不讓 `ISO8601DateFormatter` 悄悄改成別天（finding #28）。

**毫秒，截斷不進位**：事件時間與輸出時間都是毫秒解析度，多出的位數一律截斷。`ISO8601DateFormatter` 印小數秒時會**四捨五入**（實測 `…26.4786 → .479`），若游標進位就會落在沒回傳過的事件之後。第一版之所以沒出事，是因為 `DateFormatter` 解析時剛好會截斷到毫秒（實測 `.802432／.802632／.802999` 全是 `.802`）——一個沒有文件保證的副作用；verify round 1 的 logic 與 requirements 兩個 lens 因此報了 HIGH／MEDIUM，DA 用 30 萬筆反證，我實測兩邊各對一半。現在解析與輸出都自己處理小數位，不依賴框架行為，並有測試釘住。

傳給 `log show` 之前轉成本機時區的 `YYYY-MM-DD HH:MM:SS`（`--start` 是否直接接受帶時區的寫法未驗證，所以不依賴它）。時區用 `TimeZone.autoupdatingCurrent`：伺服器可能連續跑好幾天，使用者出國時 `TimeZone.current` 會停在啟動時的時區，窗口就偏了好幾個小時（finding #29）。

## Implementation Contract

**Behavior.** 呼叫 `get_mail_log_events` 回傳一個 JSON 物件，欄位：`status`、`detail`、`window {start, end}`、`coverage {first_event, last_event, source}`、`returned`、`limit`、`truncated`、`stopped_by`、`next_start`、`next_offset`、`accounts_seen`、`contains_sensitive`、`notice`（`ok` 時為 `null`）、`results`。`results` 內的簡短事件欄位固定為 `time`、`subsystem`、`category`、`event`、`kind`、`args`、`activity`、`account`；詳細事件再加 `message`、`process`、`thread`。

**Interface.** 參數：`detail`（預設 `brief`）；窗口三選一 `last_minutes`、`since`（加選用 `until`）、`around`（加選用 `radius_seconds`）；`categories`（字串陣列）；`limit`；`offset`（續查用，必須搭配 `since`）；僅詳細模式：`contains`、`redact_identifiers`。

**Failure modes.** 參數不合法（兩種窗口並用、裸時間字串、跨度超過 60 分鐘、簡短模式帶 `contains` 或 `redact_identifiers`、`categories` 含不合法字元、`limit` 或 `offset` 超出範圍、`offset` 沒有搭配 `since`、`since` 晚於 `until`）→ 回傳 invalid-parameter 錯誤，**不 spawn 子行程**。`log` 子行程 spawn 失敗、非零結束、在 deadline 或讀取上限停下而沒讀到超過游標的窗口內事件 → `status: "unavailable"`。個別 ndjson 行解析失敗 → 略過並計入 `skipped_lines`，不中斷。

**Acceptance criteria.**

1. 用合成 fixture 重建 #463 的事件鏈：存檔、建立 action、處理 action、通知引擎、`APPENDUID` 回條，簡短模式依序輸出，`APPENDUID` 為 `kind: "known"`。
2. fixture 的 `%@` 內含 email、UUID、角括號 Message-ID 時，簡短模式序列化輸出不含其中任何一個，也不符合 email／UUID／Message-ID 形狀的正規表示式。
3. 簡短模式帶 `contains` 被拒絕，且不 spawn 子行程。
4. 讀到 `limit + 1` 筆相符事件後子行程被終止並回收（用會無限輸出的假子行程驗證，5 秒內結束）。
5. 簽章後的 binary 在本機實跑，能重建 #463 的真實窗口（有人值守的 live 驗證）。

**Scope boundaries.** 在範圍內：新工具、輸出整形、子行程邊界、文件與測試。不在範圍內：事件分類表、斷鏈偵測、雙窗口比對、任何 Mail 資料的寫入、`OSLogStore` 實作（除非量測結果推翻本設計）。

## Risks / Trade-offs

- [私有格式沒有版本保證，Mail 或 macOS 更新可能改字串] → 以 `formatString` 為名稱、解析不出降級為 `unstructured`；用 fixture 釘住已知模板；已驗證版本只有 Mail 16.0／macOS 27.2，寫進 description。
- [輸出量：60 分鐘約 90 MB] → 窗口跨度上限、讀到下一個時間戳就提前終止、讀取上限 64 MiB、回應 64 KiB 上限（Claude Code 的 MCP 輸出上限是 25,000 tokens）、deadline 30 秒。
- [詳細模式的原始行含帳號識別資訊，進入 AI context 後可能被貼進公開 repo] → 回應與 description 雙重標示、選用遮蔽；機械閘的缺口已另開 PsychQuant/issue-driven-development#355。遮蔽只涵蓋三種形狀，不是保證。
- [簡短模式的 `formatString` 與數字參數是否真的不含識別資訊，依賴「`formatString` 是靜態字串」這個觀察] → 守門測試用注入識別資訊的 fixture 驗證輸出；數字參數只取整數。
- [`APPENDUID` 白名單比對靠回應碼的形狀，Apple 或 IMAP 伺服器改寫回條格式就失效] → 失效時降級為 `unstructured`，不是錯誤；fixture 釘住目前格式。
- [帳號代號依賴 `[帳號 - 信箱]` 的前綴格式，而且只在這種形式之間可比] → 解析不出就是 `account: null`，不影響其他欄位；只有模板把括號放在開頭的兩種形狀才指派；連線層的行（含上傳回條）沒有代號，description 與 README 寫明。
- [簡短模式沒有依事件名稱篩選的手段，吵的 category 會淹沒單一事件] → 用 `categories` 與短窗口縮小範圍；description 寫明並指向 #466。
- [事件到達順序＝時間順序是假設] → macOS 27.2 實測 0 次倒退（165,748 筆，DA 另量 4 個窗口）；讀到倒序就停用提前停止並在 `notice` 說明，游標放在最後回傳之後。無法偵測的只剩「停止之後才遲到、而且比最後回傳那筆更早」的事件。
- [未驗證的環境：由 Claude Desktop 的 `.mcpb` 啟動、非 `admin` 使用者] → 依 `.claude/rules/deferred-live-verification.md`，關 issue 前跑掉，或貼 `blocked-on-setup` 並在工具 description 加但書。
- [預設層級的 `log show` 不含 info 層級事件（實測 63,310 筆中 7 筆）] → 工具與 description 明講回報的是預設層級；需要 info 層級時另開 change。

## Migration Plan

純新增工具，沒有資料遷移。發布走既有 `scripts/release.sh` 與 `make release-signed`，之後依 `common-release-flow.md` 同步 plugin marketplace（`plugin.json` 的 `version` 與 `binary_version` 都要升）。回滾：不呼叫即可；移除工具只需移除註冊與對應 README 列。

## Open Questions

- `log show --start` 是否直接接受帶時區的寫法（目前不依賴它）。
- 沒有 ` - ` 的帳號標籤（例如 `[iCloud]`、`[Google]`）到底是帳號還是連線名稱：目前一律不指派代號（寧可少認），若日後確認是帳號，再放寬。
- `OSLogStore` 的記憶體在更多次呼叫後是否持平（只量了三次，每次約 +230 MB 且未歸還）；若持平且幅度可接受，值得重新評估。
- 失敗時（非 `admin` 使用者）`log show` 的 stderr 實際文字，實作時在有條件的環境確認；目前只知道會以非零結束。
- [stderr 讀取執行緒由自己關閉描述符] → 不再有描述符被重用的競態（round 3–4）；代價是若有子孫行程一直握著錯誤輸出，該執行緒與描述符會留到那個行程結束（round 5 finding 14／22）。本 change 的所有實跑（`log show --style ndjson` 加本工具的參數）都沒有觀察到這種行程；這是觀察範圍內的陳述，不是保證。追蹤：#467（已補註納入此項）。
- [截斷規則在真實日誌上**尚未驗證**] → live 腳本的 3c 會以獨立寫出的規則逐筆精確比對，但到目前為止的每一次執行，取得的窗口裡都沒有超過 8,192 位元組的訊息（`long_messages=0`），所以這條比對從未真正走到截斷；截斷規則目前只由單元測試（含逐條切點的變異檢查）保證（round 6 finding 31、round 7 finding 11）。腳本的 `CUT_WS` 是照 Swift 端在 macOS 27.2 上算出的集合寫死的，若日後系統的空白定義改變，腳本會先報不一致（偏安全的方向）。
