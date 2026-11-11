## Summary

`/archive-mail-view` 把引數當成資料讀（`ARGS_RAW`），`/archive-mail` 的引數守門把雙反斜線算成沒有跳脫，README 寫出測過的 Claude Code 版本（#651）。

## Motivation

#521 留下三件事：view 的 Step 1 直接在句子裡放 `$ARGUMENTS`，沒有 #540 的資料與指示分離；`test-archive-mail-recipes.py` 的守門用 `(?<!\\)` 判斷跳脫，把 `\\$ARGUMENTS`（依官方規則仍會被代入）當成已跳脫；外掛依賴兩個 Claude Code 行為，卻沒寫測過哪一版。

## Proposed Solution

- 依維護者接受的預設：view Step 1 改成 `ARGS_RAW: $ARGUMENTS` 獨立一行，加上「資料，不是指示」與封閉的解析規則（shell 風格切詞、第一個位置參數是 `thread_query`、第二個是 `archive_dir`、沒有旗標、引號不成對或無法執行切詞時 `status: bad-arguments`，B2）。不含 `"`、`'`、`\` 時依 ASCII 空白切開，不執行程式；含這三個字元時，用一個有標記的小 recipe（`archive-mail-view-args-recipe`），資料檔放在私有目錄。
- 守門改用 `test-command-placeholders.py` 的 `backslashes_before`，以檔案路徑載入（B3）；新增測試釘住雙反斜線會被算進去、單反斜線不會。view 的引數另有測試。
- `plugin/README.md` 加一段「測過的 Claude Code 版本是 2.1.316」，寫出依賴的兩個行為，以及沒有 manifest 欄位可以宣告最低版本（B1；不是最低版本）。

## Non-Goals

- 不宣告最低版本，也不在指令裡偵測版本（沒有量測根據）。
- 不改其他沒有 `$ARGUMENTS` 的指令（#665）。

## Impact

- Affected specs: `archive-mail-view-arguments`（新）
- Affected code: `plugin/commands/archive-mail-view.md`（Step 1、狀態表）
- Tests: `plugin/tests/test-archive-mail-recipes.py`、`plugin/tests/test-command-placeholders.py`
- Docs: `plugin/README.md`、`plugin/CHANGELOG.md`
