## 1. 測試先行（plugin/tests/test-archive-mail-recipes.py）

- [x] 1.1 寫 Example「rescue calls refused」的測試：七列的 rescue_calls 結果（Requirement: Rescue calls are produced only for mail in the junk mailbox with a readable sender）。驗證：帶標記 spec-example: archive-mail-junk-rescue / rescue calls refused，實作前失敗。
- [x] 1.2 寫 Example「mail sender fields without a bracket group」的測試：mail_sender 四列、沒有角括號的寄件人欄在計畫裡列為 sender-unreadable、兩個不是位址的鍵（Requirement: The sender address is the bracket group that ends the sender field）。驗證：帶同名標記，實作前失敗。
- [x] 1.3 寫 Example「strict record errors」的測試：NaN、Infinity、-Infinity、目錄是 symlink、超過四 MiB（Requirement: A record that is not strict JSON or is reached through a link is unusable）；另補 decided_at 形式與鍵的寫法的測試。驗證：帶同名標記，實作前失敗。
- [x] 1.4 寫 Example「recording beside a deeply nested entry」與「plan output carries recorded times, not the record」的測試（Requirement: Recording and planning never raise on a record that loaded）。驗證：兩個標記都在，實作前失敗。
- [x] 1.5 寫文字 Example「rescue step text on a failed recording」與「bulk rule text names the rescue step」的測試（Requirement: A failed recording moves nothing；Requirement: The bulk move rule does not apply to the rescue step），並把三個呼叫順序的測試改用第 3 點與工具名稱定位。驗證：帶同名標記，實作前失敗。

## 2. 實作

- [x] 2.1 改 junk recipe：rescue_calls 檢查 junk_path 與寄件人；新增 mail_sender 並用在計畫、參數與讀回；loader 拒絕非 JSON 常數、非一般檔案、過大的檔案與目錄 symlink；條目的鍵與時間形式；寫入捕捉編碼例外；plan 的輸出改帶 decided_at；讀回要求垃圾桶名稱；_names 取路徑末段。驗證：第 1.1 到 1.4 項的測試通過。
- [x] 2.2 改 Step 9、Trust boundary 與 plugin/rules/confirmation-triggers.md 的文字（Requirement: A failed recording moves nothing；Requirement: The bulk move rule does not apply to the rescue step），並在 plugin/CHANGELOG.md 的限制補上 #692、#693、#695、#696 與 junk_path 的前提。驗證：第 1.5 項與 ArchiveJunkRescueSopTests 全數通過，plugin 的十個 Python 測試檔通過。
