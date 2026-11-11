## Problem

第 1 輪 verify（#643）找到：`message_id_from_headers` 修剪標頭名稱與值的字元比伺服器少，有些標頭形狀會讀出與伺服器存的不一樣的 id，信件每次都會重寫；Step 3d 把原始標頭文字直接放進 agent 的 context，沒有資料檔的交接規則，也沒說呼叫失敗怎麼辦，失敗被報成「信沒有 Message-ID」；Step 3d 新增的（帳號, `id`）去重與「同一個 id 只呼叫一次」沒有寫進規格；held out 的信在使用者推進 `last_archived` 之後永遠不會被歸檔，報告卻沒有提醒，還把界線前的列說成「算已歸檔」。

## Root Cause

第一版只照 Diagnosis 的預設寫了讀標頭的函式，沒有寫標頭文字從工具到 recipe 怎麼走，也沒有對照伺服器的修剪規則（那份規則已經有 Swift 釘住的 fixture：`plugin/tests/fixtures/repair-message-id-spelling.json`）。

## Proposed Solution

- `message_id_from_headers` 改用伺服器的規則：在第一個空行截斷、只接回 CRLF 與 LF 的 folding、名稱與值用伺服器的修剪字元表（`HEADER_TRIM`，與 repair 指令的 `TRIMMED_CHARACTERS` 同一份）、含 RFC 5322 沒有的行界字元的區塊不讀、冒號後接組合字元時不算冒號。結果是伺服器存的值或 `None`，不會是別的 id；測試跑完整份 fixture。
- Step 3d 的交接：標頭文字寫進私有目錄的 JSON 資料檔，`message_ids_from_header_file` 只回 key 與 id；呼叫失敗寫 `null`、標記 `message_id_fetch_failed`、錯誤文字不引用；`last_archived`／`both` 只取過得了日期閘門的列；`merge_rows` 定義合併規則。
- Step 7：印最早一封 held out 的日期與不要推進界線的提醒、標頭取得失敗的數量、全部 held out 時說是 Step 3d 沒取到；定義「跳過（已歸檔）」；Step 8.5 的推進提醒納入 held out；Step 8b 標註含 held out 的 thread。

## Non-Goals

- 不讓 `search_emails` 回傳 `message_id`（伺服器工具介面的改動，另開 issue）。
- 不處理 frontmatter 寫入再讀回會改變的 id（另開 issue）。

## Success Criteria

- 對 fixture 的每一個案例，recipe 回傳伺服器存的值或 `None`；`ok` 的案例回傳伺服器存的值。
- Step 3d 不在 agent 的 context 裡留下標頭原文。

## Impact

- Affected specs: `archive-mail-dedup`（MODIFIED 兩條 requirement）
- Affected code: `plugin/commands/archive-mail.md`（dedup recipe、Step 3、3d、4.0、4.1、5.1 的 mail#319 重取、7、8b、8.5、Step 0 清單）
- Tests: `plugin/tests/test-archive-mail-recipes.py`
