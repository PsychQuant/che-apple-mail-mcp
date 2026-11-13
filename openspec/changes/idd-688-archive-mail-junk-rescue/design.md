## Context

archive-mail 的 Step 3 已經對每個帳號呼叫 get_special_mailboxes，並為了 exclude_mailboxes 的角色名展開（#594）取得 junk 與 junk_path；corpus 的每一筆都帶 mailbox。垃圾郵件匣沒有被設成排除時，裡面的信照常歸檔，SOP 之後沒有任何一步再提它，agent 只能請使用者自己到 Mail 處理（#688）。

限制有三個。第一，#395 把 archive-mail 的預授權清單收窄成讀取與匯出，並用測試鎖成集合相等；Trust boundary 明寫歸檔流程不持有 move 與 junk 的權限。第二，確認來源（Provenance）是三類的封閉列舉。第三，實測在一個 Gmail 帳號上，mark_as_junk(is_junk: false) 回報成功但信沒有離開垃圾郵件匣，要 move_email 才離開，而且搬完之後 rowId 會換（#689 追蹤工具本身的行為）。

使用者已經決定的事：救回的信放進收件匣；一次問全部；決定以寄件人為單位記在專門的 JSON 檔，記過就不再問；兩個工具加進預授權清單；沒有人在場時只列不動。

## Goals / Non-Goals

**Goals:**

- 報告列出本次歸檔、位於帳號垃圾郵件匣的信。
- 歸檔完成後一次詢問，使用者同意就由 SOP 自己把信搬回收件匣並讀回確認。
- 每個寄件人的決定留在紀錄檔，之後的執行不再問。
- 任何讀不準的情況（紀錄檔壞掉、沒有人在場、讀回不符）都不動信，並在報告講清楚。

**Non-Goals:**

- 不修 mark_as_junk 的行為（#689）。這一步以搬信加讀回為準，不依賴標記的效果。
- 不回頭處理更早的執行留下的舊檔案：它們對應的信即使還沒被救回，也不在這一步的範圍。
- 不新增獨立指令。使用者要兩個工具進 archive-mail 的預授權清單，這一步就在 archive-mail 裡。
- 不提供逐封挑選。問題只有要或不要，涵蓋題目列出的全部寄件人。
- 不做跨歸檔目標或跨 workspace 的共用紀錄。
- 不盤點 SOP 其他把工作交回使用者的地方（#688 的 Residue）。

## Decisions

### 紀錄檔放在每個歸檔目標的 state 資料夾

檔名 junk_decisions.json，位置與 email_index.json 相同（INDEX_DIR）。另一個選項是整個 workspace 共用一份，同一個寄件人在別的歸檔目標就不必再問。選每個目標一份：範圍最小，偽造寄件人位址能利用的面也最小；代價是同一個寄件人在另一個目標會再被問一次。

### 紀錄檔的格式與寄件人正規化

格式是 version 加 senders 兩個鍵；senders 的鍵是寄件人的 bare address 轉小寫（與 frontmatter 的 sender 同一條規則：去掉顯示名、去掉角括號、轉小寫），值是 decision（rescue 或 leave，封閉的兩個值）與 decided_at（帶 offset 的 ISO 時間）。decision 是其他值、或條目不是 object 時，那個寄件人視同沒有紀錄，並在報告警告。寄件人正規化後是空字串（讀不出位址）的信不能記錄，只列不動。

### 壞掉的紀錄檔只列不動

紀錄檔不是 JSON、最上層不是 object、或 senders 不是 object 時，這次執行不問、不搬、不寫，報告印一行 junk_decisions_error 與錯誤名稱。不自動覆寫或重建：壞檔可能是某些決定唯一的副本，與 email_index.json 的處理方式一致（#531）。檔案不存在是正常狀態，等於沒有任何紀錄。

### 只認完整路徑相符的垃圾郵件匣

信的 mailbox 與該帳號 junk_path 完整路徑相等才算在垃圾郵件匣；沒有 junk_path 時，與 junk 葉名完整相等（頂層）才算。只有末段相同的（例如使用者自建的 Clients/Junk）列在另一行，不詢問、不搬。理由：末段比對在 #594 已經知道會撞到使用者自建的資料夾，而這裡的後果是搬信，不是略過。

### 搬信的順序與讀回條件

每一封依序做三件事：mark_as_junk(is_junk: false)，失敗只記錄、不中止；move_email 到該帳號的 inbox_path，沒有就用 inbox；讀回。讀回用主旨重新搜尋，以主旨、寄件人、收信時間三個欄位認同一封信（搬完之後 rowId 會換，search_emails 也不能用 Message-ID 查）。垃圾郵件匣裡已經沒有它、而且別的信箱找得到它，才算已救回；其餘一律回報未確認。move_email 失敗時那一封回報失敗，其他封照常處理。

### 沒有人在場的判定是封閉的兩種

只有兩種情況算沒有人在場：這次執行被標明是無人值守（排程、headless、orchestrator 的無人值守指示）；或問了之後拿不到回答。兩種都只列不動，紀錄是 rescue 的寄件人也不搬。拿不準時當成沒有人在場。NO_CONFIRM 不影響這一步：它略過的是歸檔的確認。

### 紀錄檔裡的先前決定是第四類確認來源

Provenance 新增第四類：使用者先前在對話裡的回覆、由 Step 9 寫進紀錄檔的決定。它只對把該寄件人的信搬回收件匣這一個動作有效，不能略過其他確認。第三方 clone 帶進來、或不是由使用者的回覆寫入的紀錄檔不算。SOP 沒有辦法驗證紀錄檔是誰寫的，所以這一類的效力靠範圍限制（只有搬回收件匣、只有本次歸檔的信、只在單一歸檔目標）與揭露（照紀錄搬的每一封都列在報告，附寄件人與紀錄的 decided_at）；使用者表示某筆紀錄不是他留下的，就當成沒有那筆紀錄。

### 預授權兩個會改信箱的工具並寫死用途

frontmatter 的 allowed-tools 加入 mark_as_junk 與 move_email，CommandAllowedToolsGuardTests 的預期集合同步。Trust boundary 改寫：這兩個工具只在 Step 9、使用者同意（或紀錄檔有 rescue 的決定）之後呼叫；move_email 的來源只能是該帳號的垃圾郵件匣、目的地只能是該帳號的收件匣。這是對模型的指示，不是程式強制，所以用 SOP 文字測試釘住。

## Implementation Contract

**行為**

- Step 7 的報告多兩種行：位於垃圾郵件匣的已歸檔信件（封數與檔名）；只有末段相同、無法確認的信件。兩種都沒有時整段省略。
- 新的 Step 9 排在 Step 8.5 之後。Step 9 的結果（已救回、未確認、失敗、照紀錄留在垃圾郵件匣、只列不動的原因）附在報告末尾。
- 歸檔本身的搜尋、去重、寫檔、索引不變；Step 9 的任何失敗都不使歸檔失敗。

**介面與資料**

- archive-mail.md 新增一個 recipe，以 archive-mail-junk-recipe 的 start 與 end 標記包住，函式如下：
  - normalize_sender(value)：回傳 bare address 小寫；讀不出位址、或位址含保守字元集（英數與 . _ % + -）以外的字元時回空字串，那封信只列不動。
  - junk_candidates(written, special_by_account)：written 是本次新歸檔信件的清單（file、sender、mailbox、account_id、subject、date；date 是搜尋結果的 date 欄位），回傳 in_junk 與 last_segment 兩個清單。
  - load_junk_decisions(path)：回傳 (senders, error)；error 是 None、junk-decisions-not-json、junk-decisions-not-object、junk-decisions-senders-not-object 之一；檔案不存在回傳空的 senders 與 None。
  - plan_junk_rescue(in_junk, senders, error, attended)：回傳 move（照紀錄直接搬的信）、ask（要問的寄件人，去重、排序）、ask_mails（要問的信）、leave（照紀錄留著的信）、listed_only（只列不動的信與原因）、invalid（紀錄無效的寄件人）。
  - record_junk_decisions(path, decisions, now)：decisions 是寄件人到 rescue 或 leave 的對應；先重新載入，有錯誤就不寫並回傳錯誤名稱；寫入走暫存檔加 os.replace。
  - confirm_rescue(mail, results, junk_names)：results 是讀回搜尋的結果，回傳 rescued 或 unconfirmed。
- 紀錄檔的 JSON 形狀：{"version": "1.0", "senders": {"notice@example.invalid": {"decision": "rescue", "decided_at": "2026-11-13T08:40:00+08:00"}}}。

**失敗模式**

- 紀錄檔錯誤：報告一行 junk_decisions_error 加錯誤名稱；不問、不搬、不寫。
- move_email 失敗：該封列為失敗，附工具回傳的錯誤類別，不引用信件內容。
- 讀回不符：該封列為未確認。
- 沒有人在場：報告寫明只列不動與原因。

**驗收**

- plugin/tests/test-archive-mail-recipes.py 的新測試類別涵蓋 recipe 的每個函式與 SOP 文字（Step 9 的位置、兩個工具的用途限制、無人值守、NO_CONFIRM、Provenance 第四類），每個 spec Example 對應一個帶 spec-example 標記的測試。
- swift test 的 CommandAllowedToolsGuardTests 全數通過，archive-mail 的預期集合含 11 個工具。
- python3 plugin/tests/test-archive-mail-recipes.py 全數通過。

**範圍**

- 在範圍內：archive-mail.md、confirmation-triggers.md、上述兩個測試檔、plugin/CLAUDE.md 的 state 檔說明、plugin 的 CHANGELOG 與版號。
- 不在範圍內：Swift server 程式碼、其他 archive-mail-* 指令、archive-mail-tree 的流程。

## Risks / Trade-offs

- [以寄件人為單位的紀錄會被偽造的寄件人位址利用：冒用已記錄寄件人的信會在有人在場的下一次歸檔被搬進收件匣] → 照紀錄搬的每一封都列在報告（寄件人與檔名）；紀錄檔是純文字，使用者可以刪掉某個寄件人；只處理本次歸檔 corpus 裡的信；紀錄只在單一歸檔目標內有效。
- [預授權 move_email 擴大了讀第三方信件的指令的作用面] → SOP 寫死來源與目的地，文字測試釘住；使用者已明確決定要預授權。
- [mark_as_junk(is_junk: false) 的效果不明（#689）] → 以搬信加讀回為準，標記失敗不算救回失敗。
- [只在一個 Gmail 帳號上觀察過搬信之後的行為] → 讀回不符就回報未確認，不宣稱成功；Exchange 與 iCloud 的行為留待實測。
- [紀錄檔是 workspace 裡的檔案，可能被別人改或被 clone 帶進來] → Provenance 第四類寫明邊界；SOP 無法驗證紀錄檔的作者，照紀錄搬的每一封都在報告列出寄件人與 decided_at。
