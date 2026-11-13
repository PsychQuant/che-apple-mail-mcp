## 1. 測試先行：recipe 的行為（plugin/tests/test-archive-mail-recipes.py，新類別 ArchiveJunkRescueRecipeTests）

- [x] 1.1 寫 Example「junk classification by mailbox path」的測試：junk_candidates 對表中六列分別回傳 in_junk、last_segment 或兩者皆無（Requirement: Report lists archived mail located in the junk mailbox；設計決定「只認完整路徑相符的垃圾郵件匣」）。驗證：測試帶標記 spec-example: archive-mail-junk-rescue / junk classification by mailbox path，實作前執行為失敗。
- [x] 1.2 寫 Example「senders to ask are deduplicated and sorted」的測試：plan_junk_rescue 的 ask 是去重排序後的寄件人、已記 leave 的信進 leave 群組（Requirement: Rescue question covers every undecided sender once）。驗證：帶對應標記的測試，實作前失敗。
- [x] 1.3 寫 Example「no question when every sender is recorded」的測試：全部寄件人都有 rescue 紀錄時 ask 為空、兩封都在 move 群組。驗證：帶對應標記的測試，實作前失敗。
- [x] 1.4 寫 Example「read-back outcomes」的測試：confirm_rescue 對表中六列回傳 rescued 或 unconfirmed（Requirement: Rescue moves the mail to the account inbox and reads it back；設計決定「搬信的順序與讀回條件」）。驗證：帶對應標記的測試，實作前失敗。
- [x] 1.5 寫 Example「sender normalization」的測試：normalize_sender 對表中五列回傳小寫 bare address 或空字串（Requirement: Sender decisions are recorded in a dedicated per-target file；設計決定「紀錄檔的格式與寄件人正規化」）。驗證：帶對應標記的測試，實作前失敗。
- [x] 1.6 寫 Example「recording keeps earlier entries」的測試：record_junk_decisions 寫入後舊條目的 decision 與 decided_at 不變、新條目帶指定時間、資料夾沒有殘留暫存檔（設計決定「紀錄檔放在每個歸檔目標的 state 資料夾」）。驗證：帶對應標記的測試，實作前失敗。
- [x] 1.7 寫 Example「plan by recorded decision」的測試：plan_junk_rescue 對表中五種紀錄分別排進 move、leave 或 ask，無效條目列進 invalid（Requirement: A recorded sender is not asked again）。驗證：帶對應標記的測試，實作前失敗。
- [x] 1.8 寫 Example「record loader results」的測試：load_junk_decisions 對表中八列回傳對應的 senders 與 error 名稱（Requirement: A corrupt decision record leaves the mailbox untouched；設計決定「壞掉的紀錄檔只列不動」）。驗證：帶對應標記的測試，實作前失敗。
- [x] 1.9 寫 Example「an error plans no question and no move and refuses to write」的測試：有載入錯誤時 ask 與 move 為空、信都在 listed_only 並帶錯誤名稱、record_junk_decisions 回傳錯誤名稱且檔案內容不變。驗證：帶對應標記的測試，實作前失敗。
- [x] 1.10 寫 Example「unattended plan」的測試：attended 為 False 時 ask 與 move 為空、leave 紀錄的信在 leave 群組、其餘在 listed_only 且原因是 nobody-present（Requirement: An unattended run only lists；設計決定「沒有人在場的判定是封閉的兩種」）。驗證：帶對應標記的測試，實作前失敗。

## 2. 測試先行：SOP 與規則的文字（同一個測試檔的 ArchiveJunkRescueSopTests，與 Swift 的鎖定測試）

- [x] 2.1 寫 Example「rescue step text orders the three calls」的測試：Step 9 段落依序出現 mark_as_junk、move_email 與讀回搜尋，並寫明標記失敗只記錄、救回失敗不使歸檔失敗。驗證：帶對應標記的測試，實作前失敗。
- [x] 2.2 寫 Example「rescue step text excludes the no-confirm flag」的測試：Step 9 段落列出恰好兩種沒有人在場的情況、拿不準時當成沒有人在場、--no-confirm 不涵蓋這一步。驗證：帶對應標記的測試，實作前失敗。
- [x] 2.3 寫 Example「trust boundary text limits the two tools」的測試：Trust boundary 段落不再出現歸檔流程不持有 move 或 junk 權限的句子、寫明 11 個預授權的 mail 工具、寫明兩個工具只在 Step 9 使用且目的地只能是收件匣（設計決定「預授權兩個會改信箱的工具並寫死用途」）。驗證：帶對應標記的測試，實作前失敗。
- [x] 2.4 寫 Example「provenance lists the stored sender decision」的測試：confirmation-triggers.md 的 Provenance 編號清單有四項，第四項提到 junk_decisions.json、限定在垃圾郵件匣搬回收件匣、寫明第三方 clone 的紀錄與使用者否認的條目不算（Requirement: A stored sender decision is a consent source only for the rescue action；設計決定「紀錄檔裡的先前決定是第四類確認來源」）。驗證：帶對應標記的測試，實作前失敗。
- [x] 2.5 [P] 寫 Example「archive-mail allowed mail tools」的測試：把 CommandAllowedToolsGuardTests 中 archive-mail 的預期集合改成 11 個工具並加上標記註解（Requirement: Archive-mail pre-authorizes exactly the two mailbox-changing tools it needs）。驗證：swift test --filter CommandAllowedToolsGuardTests 在 frontmatter 修改前失敗。

## 3. 實作：recipe 與 SOP

- [x] 3.1 在 archive-mail.md 新增以 archive-mail-junk-recipe 標記包住的 recipe（normalize_sender、junk_candidates、load_junk_decisions、plan_junk_rescue、record_junk_decisions、confirm_rescue），行為照 design 的 Implementation Contract。驗證：1.1 至 1.10 的測試全數通過。
- [x] 3.2 Step 3 與 Step 5 寫明要為本次新歸檔的每封信留存 mailbox、account_id、sender、subject、date_received 供 Step 9 使用；Step 7 的報告範例加入位於垃圾郵件匣與只有末段相同兩種行，兩者皆空時省略。驗證：ArchiveJunkRescueSopTests 檢查 Step 7 段落含這兩行的說明。
- [x] 3.3 新增 Step 9（排在 Step 8.5 之後）與 Step 0 的對應 TaskCreate：一次詢問、照紀錄處理、三個呼叫的順序、讀回、壞檔與沒有人在場時只列不動、結果附在報告末尾。驗證：2.1 與 2.2 的測試通過，且 Step 9 的標題出現在 Step 8.5 之後。
- [x] 3.4 frontmatter 的 allowed-tools 加入 mark_as_junk 與 move_email，Trust boundary 段落改寫成 11 個工具與兩個工具的用途限制。驗證：2.3 與 2.5 的測試通過，swift test --filter CommandAllowedToolsGuardTests 全數通過。
- [x] 3.5 [P] confirmation-triggers.md 的 Provenance 加入第四類與它的邊界。驗證：2.4 的測試通過。

## 4. 文件與版號

- [x] 4.1 [P] plugin/CLAUDE.md 的 state 檔說明加入 junk_decisions.json 的位置、格式與「可以手動刪除某個寄件人」；plugin/CHANGELOG.md 在 Unreleased 新增條目說明新行為與預授權清單的變動。ASSUMPTION: 這個 repo 的條目累積在 Unreleased、發版時才升 plugin.json 的版號，所以這裡不升版號。驗證：python3 plugin/tests/test-archive-mail-recipes.py 與 plugin/tests 其他既有測試全數通過（含檢查版號與 CHANGELOG 一致的測試，如有）。
- [x] 4.2 跑完整驗證：python3 plugin/tests/test-archive-mail-recipes.py、swift test --filter CommandAllowedToolsGuardTests。驗證：兩個指令皆 exit 0，輸出貼進 apply 的回報。
