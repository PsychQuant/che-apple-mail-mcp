## 1. 測試先行（在第 2 輪的 head 5f7bc0a 上失敗）

- [x] 1.1 Under last_archived, mail already in a top-level file is not rewritten：`test_is_archived_reads_the_message_id_from_a_file` 帶標記 `spec-example: archive-mail-dedup / Step 5.1 check through a query file`（含 shell 特殊字元的 id 只在檔案裡）；SOP 守門：Step 5.1 寫「不得放進命令列」、不再有「兩者走 argv」。驗證：在 5f7bc0a 失敗。
- [x] 1.2 `test_cleanup_refuses_a_link_or_a_directory_elsewhere`；`test_the_skip_directory_is_removed_after_step_5` 斷言拒絕時檔案仍在（skip directory cleanup 的 Example）。驗證：在 5f7bc0a 失敗。
- [x] 1.3 `test_an_unwritable_state_directory_is_reported_not_raised`；skip file 的 Example 第 3 列斷言集合檔是 `[]`；a scan that cannot run 的第 2 列斷言集合為空；byte-order mark 的 id 被略過。驗證：在 5f7bc0a 失敗。

## 2. 實作

- [x] 2.1 dedup recipe：`is_archived(set_file, query_file)`、`remove_skip_dir(directory, state_dir)`、`write_skip_file` 不 raise、`_server_reads_back` 排除 byte-order mark。驗證：1.1–1.3 通過。
- [x] 2.2 Step 4.1、5.0、5.1 的說明。驗證：plugin 測試全綠。
