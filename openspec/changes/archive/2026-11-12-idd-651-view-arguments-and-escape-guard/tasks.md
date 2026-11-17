## 1. 測試先行（RED）

- [x] 1.1 [P] View reads its arguments from ARGS_RAW only：在 `plugin/tests/test-command-placeholders.py` 新增 `ViewArgumentsTests`：恰好一個未跳脫的 `$ARGUMENTS`，就在 `ARGS_RAW` 那一行；Step 1 的規則與 `bad-arguments`；以及帶標記 `spec-example: archive-mail-view-arguments / view argument splitting` 的 recipe 測試。驗證：`python3 -I plugin/tests/test-command-placeholders.py` 在實作前失敗。
- [x] 1.2 [P] The argument guard counts backslashes：`plugin/tests/test-archive-mail-recipes.py` 的守門改用載入的 `backslashes_before`；帶標記 `spec-example: archive-mail-view-arguments / escaped and unescaped placeholders` 的測試。驗證：在 `archive-mail.md` 的副本加一行 `\\$ARGUMENTS`，舊的 `(?<!\\)` 守門只數到一個、新的數到兩個。

## 2. 實作（GREEN）

- [x] 2.1 `plugin/commands/archive-mail-view.md` Step 1、`archive-mail-view-args-recipe`、狀態表的 `bad-arguments` 一列。驗證：1.1 通過。
- [x] 2.2 守門的計數函式。驗證：1.2 通過，既有 `ArchiveArgsStructureTests` 維持綠。

## 3. 文件

- [x] 3.1 `plugin/README.md` 測過的版本說明（不是最低版本，不寫「或更新」）與 `plugin/CHANGELOG.md` 條目。驗證：README 守門測試與 `EscapeCommentTests` 維持綠。
