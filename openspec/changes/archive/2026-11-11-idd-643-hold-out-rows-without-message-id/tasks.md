## 1. 測試先行（RED）

- [x] 1.1 [P] Message-ID comes from get_email_headers：在 `plugin/tests/test-archive-mail-recipes.py` 新增 `ArchiveDedupRecipeTests`，帶標記 `spec-example: archive-mail-dedup / message id from raw headers`，逐列檢查 `message_id_from_headers` 對該 Example 每一列的結果。驗證：`python3 -I plugin/tests/test-archive-mail-recipes.py` 在實作前失敗（recipe 標記不存在）。
- [x] 1.2 [P] Rows without a usable Message-ID are held out, not archived：同一個 class，帶標記 `spec-example: archive-mail-dedup / rows decided by Step 4.1`，逐列檢查 `split_new(refined, make_is_new(...))` 把每一列分到 `new_emails`、`held_out` 或兩者皆非，且不丟例外。驗證：實作前失敗。
- [x] 1.3 [P] 帶標記 `spec-example: archive-mail-dedup / held out rows under a date boundary`：`last_archived` 下沒有 Message-ID 的列只在晚於界線時列入 `held_out`。驗證：實作前失敗。
- [x] 1.4 [P] 帶標記 `spec-example: archive-mail-dedup / held out report lines`：`held_out_report` 的空清單、單筆、25 筆上限、含換行與反引號的主旨四種輸出。驗證：實作前失敗。
- [x] 1.5 SOP 文字守門（`ArchiveDedupSopTests`）：Step 3d 寫出 `get_email_headers` 與 `message_id_from_headers`；Step 4.1 呼叫 `split_new`、不再有 `email["message_id"] in known_ids`；Step 4.5 與 Step 7 提到 `held_out_lines`。驗證：實作前失敗。

## 2. 實作（GREEN）

- [x] 2.1 `plugin/commands/archive-mail.md` Step 4.1 改為 `archive-mail-dedup-recipe` 標記的 recipe（`usable_message_id`、`message_id_from_headers`、`make_is_new`、`split_new`、`held_out_report`），沒有可用 Message-ID 的列進 `held_out` 而不丟例外；Step 4.0 的呼叫順序改用 `make_is_new`。驗證：1.1–1.4 轉綠，`ArchiveRefinementRecipeTests` 維持綠。
- [x] 2.2 Step 3d 寫明 `message_id` 來自 `get_email_headers` 並以 `message_id_from_headers` 讀取；Step 4.5 預覽與 Step 7 報告加上 held-out 區塊與說明。驗證：1.5 轉綠。

## 3. 文件

- [x] 3.1 `plugin/CHANGELOG.md` 的 `## [Unreleased]` / `### Fixed` 加一則條目。驗證：內容審閱；`make test` 的 plugin 套件全綠。
