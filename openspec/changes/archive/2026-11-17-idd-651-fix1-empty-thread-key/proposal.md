## Summary

`/archive-mail-view` 的 Step 1 把「引號括起來的空字串或空白」當成 `thread_query`，不再停止（#651 驗證第 1 輪的 Blocking）。

## Motivation

規格第一條寫「空的或缺少的 `thread_query` 停止並報 `bad-arguments`」，但 Step 1 的規則 4 只涵蓋「沒打引數、切詞後沒有 token」。`"" key`、`""`、`" " key` 切詞後有 token，所以照字面讀的人會拿空字串當 thread key；Step 3 的子字串比對會讓空字串符合每一個 thread key。

## Proposed Solution

- recipe 的 `split_view_arguments` 在第一個 token 是空字串或只有空白時回 `error: "empty-thread-query"`、`tokens: []`。
- 規則 4 與狀態表的 `bad-arguments` 一列寫出這一種；規格第一條與它的 Example 表加上這幾列。
- 測試：Example 表的新列、規則 4 與狀態表的文字。

## Non-Goals

- 第二個 token 為空字串（`key ""`）不在這次處理：它會讓 `archive_dir` 變成空字串而不是預設值，記在後續 issue。
- 不改 `ARGS_RAW` 的其他規則，也不新增 status。

## Impact

- Affected specs: `archive-mail-view-arguments`（MODIFIED 第一條）
- Affected code: `plugin/commands/archive-mail-view.md`（Step 1 規則 4、recipe、狀態表）
- Tests: `plugin/tests/test-command-placeholders.py`
- Docs: `plugin/CHANGELOG.md`
