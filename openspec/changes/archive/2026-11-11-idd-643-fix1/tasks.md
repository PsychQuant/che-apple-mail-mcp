## 1. 測試先行（RED，在第 1 輪的 head 上執行時失敗）

- [x] 1.1 Message-ID comes from get_email_headers：`test_the_recipe_never_disagrees_with_the_server` 帶標記 `spec-example: archive-mail-dedup / server parity on the pinned fixture`，跑完整份 fixture，並比對 `HEADER_TRIM` 與 fixture 的字元表。驗證：在 ee71e05 失敗，現在通過。
- [x] 1.2 `test_rows_merged_by_step_3d` 帶標記 `spec-example: archive-mail-dedup / rows merged by Step 3d`；`test_message_ids_from_a_header_file` 檢查失敗的呼叫回 `None`。驗證：在 ee71e05 失敗。
- [x] 1.3 Rows without a usable Message-ID are held out, not archived：`test_the_earliest_held_out_day_is_reported`、報告測試改為比對完整字串、加入舊判斷式與新判斷式的差異測試（`test_rows_with_a_usable_id_are_decided_as_before`）。驗證：在 ee71e05 失敗。
- [x] 1.4 SOP 守門：Step 3d 的交接與失敗規則、Step 7 的新行、Step 8.5 的提醒、舊句子不再出現。驗證：在 ee71e05 失敗。

## 2. 實作（GREEN）

- [x] 2.1 dedup recipe：`HEADER_TRIM`、`AMBIGUOUS_LINE_BOUNDARIES`、新的 `message_id_from_headers`、`message_ids_from_header_file`、`merge_rows`、`earliest_held_out_day`。驗證：1.1–1.3 通過。
- [x] 2.2 `plugin/commands/archive-mail.md` 的 Step 0、3、3d、4.0、4.1、5.1（mail#319 重取）、7、8b、8.5。驗證：1.4 通過；plugin 測試全綠。
