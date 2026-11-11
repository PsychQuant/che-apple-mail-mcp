## 1. 測試先行（RED）

- [x] 1.1 [P] Under last_archived, mail already in a top-level file is not rewritten：在 `plugin/tests/test-archive-mail-recipes.py` 新增 `ArchiveArchivedSetTests`，帶標記 `spec-example: archive-mail-dedup / archived ids from a scan report`，逐列檢查 `archived_message_ids`，並以真實的 `scan_report` 掃一個暫存目錄確認 `archived_set` 回傳集合、檔數與秒數。驗證：`python3 -I plugin/tests/test-archive-mail-recipes.py ArchiveArchivedSetTests` 在實作前失敗。
- [x] 1.2 [P] 帶標記 `spec-example: archive-mail-dedup / skip file contents`：`write_skip_file` 的行、遺漏數、目錄在 state 目錄底下且權限 0700、兩次呼叫路徑不同。驗證：實作前失敗。
- [x] 1.3 [P] 帶標記 `spec-example: archive-mail-dedup / rows decided with the archived set`：`split_new` 與 `count_archived_hits` 逐列結果。驗證：實作前失敗。
- [x] 1.4 SOP 文字守門（`ArchiveArchivedSetSopTests`）：Step 4.1 呼叫 `archived_set`、Step 5.0 傳 `skip_message_ids_path` 與 `write_skip_file`、Step 5.1 檢查 `ARCHIVED_IDS`、Step 7 有新的一行；舊的 `-N` 承諾句不再出現。驗證：實作前失敗。

## 2. 實作（GREEN）

- [x] 2.1 dedup recipe 加入 `archived_message_ids`、`archived_set`、`write_skip_file`、`count_archived_hits`；Step 4.1 呼叫在 `last_archived` 時把集合併入 `known_ids`。驗證：1.1–1.3 轉綠。
- [x] 2.2 Step 5.0、Step 5.1、Step 7、Step 8.5 掃描段落、`is_after_watermark` docstring 與 Step 4.1 #600 段落改寫；`plugin/CLAUDE.md` 的 `dedup_strategy` 列。驗證：1.4 轉綠，既有 `ArchiveWatermarkTests` 的 SOP 守門改成新句子後維持綠。

## 3. 文件

- [x] 3.1 `plugin/CHANGELOG.md` 的 `## [Unreleased]` / `### Fixed` 加一則條目。驗證：內容審閱；plugin 測試全綠。
