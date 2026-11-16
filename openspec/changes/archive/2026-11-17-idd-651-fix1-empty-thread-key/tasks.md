## 1. 測試先行（RED）

- [x] 1.1 View reads its arguments from ARGS_RAW only：在 `plugin/tests/test-command-placeholders.py` 的 `test_view_argument_splitting` 加上 `"" key`、`""`、`" " key`、全形空白的列（error `empty-thread-query`）與 `key ""`（不是錯誤），並新增規則 4 與狀態表文字的測試。驗證：實作前失敗。

## 2. 實作（GREEN）

- [x] 2.1 `plugin/commands/archive-mail-view.md` 的 recipe、規則 4、狀態表。驗證：1.1 通過；把 recipe 的新判斷拿掉，1.1 轉紅。

## 3. 文件

- [x] 3.1 `plugin/CHANGELOG.md` 的 #651 條目補上這一種停止。
