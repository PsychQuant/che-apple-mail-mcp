## Problem

第 2 輪 verify（#652）：Step 5.1 把寄件人控制的 Message-ID 放上命令列給 `is_archived`；`remove_skip_dir` 只檢查目錄名稱，會跟著 symbolic link 走、也不限定在 state 目錄底下；`write_skip_file` 沒有防護，state 目錄寫不了就讓 Step 4 程序停下；skip file 的讀回規則漏了伺服器會拿掉的一個前綴；三個 spec-example 測試各漏斷言一格。

## Proposed Solution

- Step 5.1 寫一個查詢檔（`get_email` 的 `message_id`，或 mail#319 重取的標頭純文字檔名），`is_archived(set_file, query_file)` 只收兩個路徑，回 `{"has_message_id", "archived"}`，不 raise。
- `remove_skip_dir(directory, state_dir)`：必須是 state 目錄底下、不是 symbolic link 的 `skip-ids-*` 目錄，裡面只有那兩個一般檔，否則拒絕且什麼都不刪。
- `write_skip_file` 不 raise，失敗時回錯誤型別；以 byte-order mark 開頭的 id 不寫進 skip file。
- skip file 被伺服器拒絕後，本 run 之後的批次呼叫都不帶它。
- 補上三個 Example 欄位的斷言。

## Non-Goals

- 只列 Step 4.1 的略過清單；Step 5.0／5.1 的略過仍只有數量（併入 follow-up issue）。

## Success Criteria

- 含 shell 特殊字元的 Message-ID 只出現在資料檔裡。
- `remove_skip_dir` 對 symbolic link 與別處的目錄一律拒絕，目標檔案不受影響。

## Impact

- Affected specs: `archive-mail-dedup`（MODIFIED 一條）
- Affected code: `plugin/commands/archive-mail.md`
- Tests: `plugin/tests/test-archive-mail-recipes.py`
