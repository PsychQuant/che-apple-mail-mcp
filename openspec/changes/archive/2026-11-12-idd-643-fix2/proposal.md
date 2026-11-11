## Problem

第 2 輪 verify（#643）：dedup recipe 新增的 `_listed` 與 refinement recipe 的 `_listed` 同名，兩者貼進同一個程序後每個 run 都在 Step 4 停下；Step 3d 仍要 agent 把標頭文字手動跳脫成一個 JSON 檔、再把 id 抄回各列；`merge_rows` 留下已取得 id 那一列的無 id 雙胞胎；一些刻意構造的非 ASCII 標頭形狀仍可讓 recipe 讀出伺服器不會存的 id；Step 3d 的日期篩選沒有「界線已設定」的條件；SOP 有幾條規格沒寫的行為。

## Root Cause

第 1 輪修正為 LOW 項目加了約八個函式與說明，沒有一個測試把四個 recipe 照 SOP 的順序組在一起執行。

## Proposed Solution

- 把 dedup recipe 的 `_listed` 改名為 `_bounded_rows`；新增測試：四個 recipe 照 SOP 順序組成一個程序跑一次完整流程，並檢查這四個 recipe 沒有同名的頂層定義。
- Step 3d：每次 `get_email_headers` 的回傳原樣寫成一個純文字檔，加一個 `fetched.json` 清單；Step 4 程序裡的 `fill_message_ids` 讀檔、把 id 寫給同一個（帳號, `id`）的每一列，只印數量；移除 `message_ids_from_header_file` 與 Step 3d 的日期篩選（第 1 輪的 LOW 加的）。
- `merge_rows` 不論順序，丟掉同一個（帳號, `id`）已有帶 id 列的無 id 列。
- `message_id_from_headers`：fold 的空白或 tab 後、Message-ID 行冒號後直接接非 ASCII 字元時整塊回 `None`；規格寫明伺服器的截斷規則。
- 移除規格沒寫的行為：Step 8b 的標註、「跳過（已歸檔）」的公式、中途停止也要刪 skip 目錄與刪不掉時的那一行、`left_out` 的註記；mail#319 的重取回到原本的寫法（其他策略不受影響）。
- 「全部 held out」那一行改為「沒有取得任何可用的 Message-ID」並附三個數字，只在至少一列過了日期閘門時才印。

## Non-Goals

- 工具回傳必然進 agent 的 context；不逐列取標頭的做法是 #682。
- 第 2 輪的 LOW 項目（UTC 日期的提醒、Step 7 標籤、伺服器端略過的清單、Step 8.5 參考值等）合成一張 follow-up issue。

## Success Criteria

- 四個 recipe 照 SOP 順序組成的程序對 `index`、`last_archived`、`both` 各跑一次完整流程都不 raise。
- 沒有任何 Message-ID 經由 agent 抄寫或放上命令列。

## Impact

- Affected specs: `archive-mail-dedup`（MODIFIED 兩條）
- Affected code: `plugin/commands/archive-mail.md`
- Tests: `plugin/tests/test-archive-mail-recipes.py`
