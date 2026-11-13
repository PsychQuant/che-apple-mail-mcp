## 1. 測試先行（plugin/tests/test-archive-mail-recipes.py，類別 ArchiveJunkRescueRecipeTests 與 ArchiveJunkRescueSopTests）

- [x] 1.1 改寫 Example「junk classification by mailbox path」的測試：沒有 junk_path 而葉名相同、頂層匣名等於巢狀垃圾郵件匣的葉名都歸 last_segment；特殊信箱沒讀到、mailbox 是空字串的信算進 unreadable（Requirement: Report lists archived mail located in the junk mailbox）。驗證：測試帶標記 spec-example: archive-mail-junk-rescue / junk classification by mailbox path，實作前失敗。
- [x] 1.2 改寫 Example「read-back outcomes」的測試為十二列：垃圾桶、寄件人讀不出的垃圾郵件匣列、別的帳號、沒有 account_id、空字串 mailbox 都回 unconfirmed，時間寫成 +00:00 仍回 rescued（Requirement: Rescue moves the mail to the account inbox and reads it back）。驗證：帶標記 read-back outcomes，實作前失敗。
- [x] 1.3 寫 Example「ambiguous sender fields」的測試：八列的 normalize_sender 結果（Requirement: The sender address is the bracket group that ends the sender field）。驗證：帶標記 ambiguous sender fields，實作前失敗。
- [x] 1.4 寫 Example「plan follows the record at the time it is computed」的測試：命令列 plan 跑兩次、中間把紀錄檔換成非 JSON，第二次的 move 是空的（Requirement: The rescue step computes its plan from the current record）。驗證：帶標記同名。
- [x] 1.5 寫 Example「record form errors」與「entries that are not recorded decisions」的測試：version、重複鍵、symlink 的錯誤名稱；沒有帶 offset 的 decided_at 的條目判為 invalid（Requirement: The decision record is used only in the form the rescue step writes）。驗證：兩個測試各帶同名標記，實作前失敗。
- [x] 1.6 寫 Example「mails that are only listed before any call」與「rescue calls for one mail」的測試：四種只列不動的原因；rescue_calls 回傳三個呼叫的確切參數（Requirement: Nothing is changed for a mail whose rescue cannot be completed and checked）。驗證：兩個測試各帶同名標記，實作前失敗。
- [x] 1.7 寫 Example「recording beside an unencodable key」的測試：既有鍵含單獨的 surrogate 時記錄成功、檔案是 ASCII（Requirement: A failed record write is reported by name and never raises）。驗證：帶標記同名，實作前失敗。
- [x] 1.8 寫五個文字 Example 的測試：「rescue step text recomputes the plan」「rescue step text shows recorded moves first」「trust boundary text excludes the registered-target flow」「provenance scopes flags and settings out of the rescue」「step order text」，並更新「rescue step text orders the three calls」加上 move_email 錯誤後照樣讀回。驗證：各帶同名標記，實作前失敗。

## 2. 實作

- [x] 2.1 改 junk recipe：normalize_sender 取結尾的角括號組並拒絕有歧義或非 ASCII 的欄位；junk_candidates 以 junk_path 完整相等判定、計數判定不了的信；load_junk_decisions 拒絕 symlink、重複鍵與非 1.0 的 version；條目要有帶 offset 的 decided_at；新增 readback_query、rescue_calls 與命令列的 calls；confirm_rescue 以帳號、垃圾桶與「可能是這封信」的規則判定；record_junk_decisions 寫 ASCII、失敗一律回錯誤名稱。驗證：第 1 組的 recipe 測試通過。
- [x] 2.2 改 Step 9 的文字（Requirement: Recorded moves are shown before they happen and the question says what is remembered；Requirement: The rescue step computes its plan from the current record）：開始時與記下答案後重算計畫；照紀錄搬的信先列出；題目說明答案會記下來；參數由 calls 產生；move_email 錯誤後照樣讀回；rescued 的意思；Step 8.5 未通過時不執行；已登錄目標不在範圍。驗證：第 1.8 項的文字測試通過。
- [x] 2.3 （Requirement: The rescue step follows a reconcile gate that passed；Requirement: Registered archive targets are outside the rescue step）改 Step 3（拿掉 account_id 補值）、Step 5（以 account_id 與 id 對應）、Step 7（判定跑不了時的揭露行、Step 8.5 未通過的說明）、Step 8.5 與 Step 0（不再自稱 run 的最後一件事）、Trust boundary（tree 流程不呼叫兩個工具）。驗證：ArchiveJunkRescueSopTests 全數通過，其餘既有測試不變紅。
- [x] 2.4 （Requirement: A flag or a workspace setting never authorizes the rescue move）改 plugin/rules/confirmation-triggers.md：第 4 類寫明無法驗證紀錄檔的作者與搬移前先列出；新增一句第 2、3 類都不授權這個搬移。驗證：Provenance 的兩個測試通過。
- [x] 2.5 改 plugin/CLAUDE.md（手動只指刪除條目）與 plugin/CHANGELOG.md（Unreleased 的 #688 條目補上修正後的行為與已登錄目標的限制）。驗證：test_the_plugin_guide_only_invites_deleting_entries 通過；plugin 的十個 Python 測試檔與 swift test 的 CommandAllowedToolsGuardTests 通過。
