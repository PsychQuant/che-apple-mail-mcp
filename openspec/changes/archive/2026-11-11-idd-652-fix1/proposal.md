## Problem

第 1 輪 verify（#652）找到：掃描失敗的處理只寫在說明裡，`archived_set` 一 raise 整個 Step 4 程序就停（連 #509 的 refinement 報告一起消失）；`ARCHIVED_IDS` 從 Step 4.1 的程序到 Step 5.0／5.1 沒有定義怎麼走，最可能的做法會把第三方的 id 印進 agent 的 context；skip 目錄每個 run 留一個、從不刪除；伺服器以政策拒絕 skip file 時每次批次都失敗並退回 Step 5.1，失去 `skip_drafts`；Step 7 只給數量，看不出是哪幾封被頂層檔案擋下；AppleScript 路徑上 Step 5.1 的檢查永遠不會觸發；skip-file 的 spec-example 測試沒有照 Example 那一列檢查。

## Root Cause

第一版把「集合」寫成跨步驟的變數，沒有把它落成檔案；失敗路徑只用文字描述。

## Proposed Solution

- `archived_set` 不 raise：失敗時回空集合與例外的型別名稱。
- Step 4.1 的程序在同一處呼叫 `write_skip_file`，每個 run 一個私有目錄、兩個檔（給伺服器的 skip file、給 Step 5.1 的完整集合 JSON），只印路徑與數量；Step 5.1 用 `is_archived(set_file, message_id)`；Step 5 之後 `remove_skip_dir` 刪掉該目錄。
- 批次呼叫因 skip file 被拒時不帶它重送一次並在 Step 7 說明。
- `archived_hits` 回傳列，Step 7 列出（最多 20 筆，資料區塊）。
- Step 5.1 的 mail#319 重取經 `message_id_from_headers`，之後再查集合。
- `write_skip_file` 的排除規則與伺服器讀 skip file 的修剪規則一致。

## Non-Goals

- 不處理 frontmatter 寫入再讀回會改變的 id（另開 issue）。

## Success Criteria

- `output_dir` 不是目錄或讀不了時，Step 4 照常產生 `new_emails` 與報告，Step 7 寫出缺口。
- 任何 Message-ID 都不會被印進 agent 的 context。

## Impact

- Affected specs: `archive-mail-dedup`（MODIFIED 一條 requirement）
- Affected code: `plugin/commands/archive-mail.md`（dedup recipe、Step 1.6 策略表、Step 2.1、Step 4.1、5.0、5.1、7）、`plugin/CLAUDE.md`（File Layout）
- Tests: `plugin/tests/test-archive-mail-recipes.py`
