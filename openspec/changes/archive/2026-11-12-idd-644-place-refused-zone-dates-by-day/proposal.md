## Summary

`thread_sort_key` 把時區名稱讀不懂（例如裸 `CST`、`KST`）的日期放在它寫明的那一天，不再排到整串最後（#644）。

## Motivation

`/archive-mail`、`/archive-mail-rebuild-threads` 與 `/archive-mail-view` 以 `thread_order` 排序一串信（#556）。`parse_archive_date` 拒絕的時區名稱讓整個值變成「讀不出來」，排到每一封可讀的信之後：一月、十二月、六月、七月這種錯位差的是幾個月，不是一天。`to_ymd` 其實讀得出那一天。

## Proposed Solution

- 依維護者接受的預設（B1 選項 c、B2 維持）：`parse_archive_date` 讀不出、`to_ymd` 讀得出日期的值，排在那一天的開頭（同只有日期的值）；兩者都讀不出的照舊排最後。
- `thread_order` 照舊列出所有 `parse_archive_date` 讀不出的值（包括這些依日期排的），rebuild 與 view 仍會點名它們。
- `thread_bounds` 只用 `parse_archive_date` 讀得出的值，`first_message`／`last_message` 的意思不變。
- 說明文字：只有日期、沒有時區與時區不明的值，一天之內的先後無法從歸檔還原；`-0000` 依 UTC 時刻排序。rebuild Step 6 的報告行改為「有日期就依日期排，否則排最後」。

## Non-Goals

- 不存 Mail 的 `date_received`（選項 b，要改 frontmatter）。
- 不改 `parse_archive_date` 接受的時區名稱。

## Alternatives Considered

- 只寫說明（選項 a）：月份級的錯位仍在，未採用。

## Impact

- Affected specs: `archive-mail-thread-order`（新）
- Affected code: `plugin/commands/archive-mail.md`（日期 recipe）、`plugin/commands/archive-mail-rebuild-threads.md`（Step 4、Step 6）、`plugin/commands/archive-mail-view.md`（Step 4）
- Tests: `plugin/tests/test-archive-mail-recipes.py`
- Docs: `plugin/CHANGELOG.md`（Unreleased）
