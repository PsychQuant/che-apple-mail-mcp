## 1. 測試先行（RED，在第 1 輪的 head 上執行時失敗）

- [x] 1.1 Under last_archived, mail already in a top-level file is not rewritten：`test_a_failed_scan_gives_an_empty_set_and_a_type_name` 帶標記 `spec-example: archive-mail-dedup / a scan that cannot run`。驗證：在 ee71e05 失敗，現在通過。
- [x] 1.2 `test_skip_file_contents` 帶標記 `spec-example: archive-mail-dedup / skip file contents`，照 Example 第二列斷言（1 行、3 個略過），另以 `test_ids_the_server_would_read_back_differently_are_left_out` 檢查空白 id 與 `HEADER_TRIM` 字元。驗證：在 ee71e05 失敗。
- [x] 1.3 `test_the_skip_directory_is_removed_after_step_5` 帶標記 `spec-example: archive-mail-dedup / skip directory cleanup`；`test_is_archived_reads_the_set_file`。驗證：在 ee71e05 失敗。
- [x] 1.4 `test_rows_decided_with_the_archived_set` 帶標記 `spec-example: archive-mail-dedup / rows decided with the archived set`，逐列檢查 `archived_hits`；`test_the_hits_are_listed`。驗證：在 ee71e05 失敗。
- [x] 1.5 SOP 守門：Step 4.1、5.0、5.1、7 的新規則與舊句子不再出現。驗證：在 ee71e05 失敗。

## 2. 實作（GREEN）

- [x] 2.1 dedup recipe：`archived_set` 不 raise、`write_skip_file` 回傳 dict 並寫兩個檔、`is_archived`、`remove_skip_dir`、`archived_hits`、`archived_hits_report`。驗證：1.1–1.4 通過。
- [x] 2.2 Step 1.6 策略表、Step 2.1、Step 4.1、5.0、5.1、7 與 `plugin/CLAUDE.md` File Layout。驗證：1.5 通過；plugin 測試全綠。
