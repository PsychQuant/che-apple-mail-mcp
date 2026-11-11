## 1. 測試先行（在第 2 輪的 head 5f7bc0a 上失敗）

- [x] 1.1 Message-ID comes from get_email_headers：`ArchiveStep4ProgramTests`（四個 recipe 照 SOP 順序組成程序跑一次完整流程；沒有同名頂層定義）；`test_fill_message_ids_from_header_files` 帶標記 `spec-example: archive-mail-dedup / message ids filled from header files`；`test_an_unreadable_manifest_marks_rows_failed_and_never_raises`；`test_crafted_non_ascii_next_to_a_colon_or_fold_gives_none`；`test_rows_merged_by_step_3d` 加上雙胞胎列。驗證：在 5f7bc0a 失敗，現在通過。
- [x] 1.2 Rows without a usable Message-ID are held out, not archived：Step 7 的守門改為新的措辭與 `fetch_counts`。驗證：在 5f7bc0a 失敗。

## 2. 實作

- [x] 2.1 dedup recipe：`_bounded_rows`、`fill_message_ids`、order-independent `merge_rows`、`message_id_from_headers` 的非 ASCII 規則；移除 `message_ids_from_header_file`。驗證：1.1 通過。
- [x] 2.2 `plugin/commands/archive-mail.md` Step 0、3d、4.1、7、8b 與 mail#319 那一句。驗證：1.2 通過；plugin 測試全綠。
