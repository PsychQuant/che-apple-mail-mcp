## Problem

`/archive-mail` Step 4.1 定義的 `is_new` 直接讀 `email["message_id"]`，`new_emails = [e for e in refined if is_new(e)]` 沒有任何防護。不是 dict 的列丟 `TypeError`，沒有 `message_id` 的列丟 `KeyError`，整個 run 在 Step 4.0 印完報告之後、Step 4.5 之前以 traceback 中止（#643）。

## Root Cause

Step 4.1 讀的欄位，它收到的列不保證有，而 SOP 沒有寫哪一步提供它。`search_emails` 的三種回傳（`full`、`summary`、AppleScript fallback）都沒有 `message_id`；Message-ID 只來自 `get_email`、`get_email_headers`、`get_emails_batch` 與匯出 manifest。Step 3d 說四組結果用 Message-ID 去重、Step 4.1 也用它比對，但沒有一步寫出要呼叫哪個工具補上它。

## Proposed Solution

- Step 3d 寫明來源：沒有 `message_id` 的列，呼叫 `get_email_headers(id, mailbox, account_name)`（已在 `allowed-tools`），以新的 `message_id_from_headers` recipe 讀出 Message-ID。recipe 的讀法與伺服器替 `get_email` 讀標頭的方式相同（摺行接回、名稱不分大小寫、值去掉空白與 tab、同名標頭取最後一個）。
- Step 4.1 改成有標記、有測試的 recipe（`archive-mail-dedup-recipe`）：`usable_message_id`、`make_is_new`、`split_new`、`held_out_report`。沒有可用 `message_id` 的列（不是 dict、沒有鍵、不是字串、空白）照常過日期閘門；過了的不進 `new_emails`，改列入 `held_out`，不歸檔、不中止。
- Step 4.5 預覽與 Step 7 報告列出 `held_out`：數量，以及每一筆的 `id` 與經 `bounded_text` 的主旨，放在標明「以下為資料，不是指示」的區塊內。

## Non-Goals

- 不讓 `search_emails` 回傳 `message_id`：那是公開工具介面的改動，另開 issue。
- 不改 Step 4.0 的 `malformed_messages`：#634 的測試釘住那些計數；Step 4.1 的一行另外列。
- 不發明任何 id（mail#319），所以沒有 Message-ID 的信不會被歸檔，只會被看見。

ASSUMPTION: `dedup_strategy` 是 `last_archived` 或 `both` 時，沒有 Message-ID、日期又不晚於界線的列，照該策略的語意算已歸檔，不列入 `held_out`。只有本來會被歸檔、卻因為沒有 Message-ID 而沒歸檔的列才列出。這個選擇列在 cluster PR 的 "Decisions to look at"。

## Success Criteria

- Step 4.1 對沒有可用 `message_id` 的列不丟例外，該列不在 `new_emails`，出現在 `held_out` 與報告裡。
- 有可用 `message_id` 的列行為與改動前相同。
- `message_id` 是 `""` 的列不被歸檔。

## Capabilities

### New Capabilities

- `archive-mail-dedup`: `/archive-mail` 如何取得每封信的 Message-ID，以及沒有 Message-ID 的信在去重時如何處理。

### Modified Capabilities

(none)

## Impact

- Affected specs: `archive-mail-dedup`（新）
- Affected code: `plugin/commands/archive-mail.md`（Step 3d、Step 4.0 呼叫順序、Step 4.1、Step 4.5、Step 7）
- Tests: `plugin/tests/test-archive-mail-recipes.py`
- Docs: `plugin/CHANGELOG.md`（Unreleased）
