## 1. 測試先行（plugin/tests/test-archive-mail-recipes.py）

- [x] 1.1 寫 Example「a write that would exceed the size limit」的測試，並把 Example「record loader results」裡只有 version 的那一列改成回報 junk-decisions-senders-not-object（Requirement: Sender decisions are recorded in a dedicated per-target file；Requirement: A corrupt decision record leaves the mailbox untouched）。驗證：帶標記 spec-example: archive-mail-junk-rescue / a write that would exceed the size limit，實作前失敗。
- [x] 1.2 在 Example「mails that are only listed before any call」的測試加上帳號沒有垃圾桶名稱的那一列（Requirement: Nothing is changed for a mail whose rescue cannot be completed and checked），並補時間溢位與過長寄件人欄的測試。驗證：實作前失敗。
- [x] 1.3 寫 Example「rescue step text on a failed recipe call」的測試（Requirement: A failed recipe call stops the rescue step），並加上寫入失敗後帶答案重算、產生參數的串接測試與 confirmation-protocol skill 的文字測試。驗證：帶同名標記，實作前失敗。

## 2. 實作

- [x] 2.1 改 junk recipe：senders 鍵必須存在；寫入前檢查大小；搬移前檢查垃圾郵件匣與垃圾桶名稱；讀回搜尋的時間溢位；寄件人欄的長度上限。驗證：第 1.1、1.2 項的測試通過。
- [x] 2.2 改 Step 9 的文字與 plugin/skills/confirmation-protocol/SKILL.md。驗證：第 1.3 項與 plugin 的十個 Python 測試檔通過。
