## 1. 測試先行（plugin/tests/test-archive-mail-recipes.py）

- [x] 1.1 寫 Example「plan with answers that could not be stored」的測試：表中四列的 move、leave、ask 與只列不動的原因（Requirement: An answer that could not be stored still applies to the run that asked）。驗證：帶標記 spec-example: archive-mail-junk-rescue / plan with answers that could not be stored，實作前失敗。
- [x] 1.2 寫 Example「rescue step text on an unrecorded answer」的測試，並確認既有的「rescue step text on a failed recording」仍然成立（它隨著被移除的 Requirement: A failed recording moves nothing 搬到新的 requirement 底下）。驗證：帶同名標記，實作前失敗。

## 2. 實作

- [x] 2.1 plan_junk_rescue 新增選用的 answers 參數與命令列 plan 的 answers 欄位；Step 9 在寫入失敗時帶答案重算計畫並照它搬，其他錯誤照舊；摘要範本與 plugin/CHANGELOG.md 補上「答案沒有記下來」。驗證：第 1 組的測試與 plugin 的十個 Python 測試檔通過。
