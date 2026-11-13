## Problem

#688 的第 3 輪 verify 判定通過、沒有 Blocking，但留下 13 項要修的意見，其中 5 項是 MEDIUM：主規格有一句舊條文（答案記不下來就不搬）與維護者的決定相反；沒有 senders 鍵的紀錄檔被當成空的紀錄；寫入端可以寫出超過 4 MiB、讀取端會拒絕的檔；帳號沒有垃圾桶名稱時信照樣被搬、卻永遠無法確認；Step 9 有幾種狀態沒有指示。

## Root Cause

idd-688-fix3 只移除了一條舊 requirement，沒有一併修改另一條裡的同一句話；第 2 輪加上的大小上限與垃圾桶檢查只做在讀取與讀回，沒有做在寫入與搬移前的檢查。

## Proposed Solution

- 刪掉主規格裡那半句，改成指向新的 requirement；寫入超過大小上限算寫入失敗。
- senders 鍵必須存在而且是 object。
- 帳號沒有回報垃圾郵件匣或垃圾桶名稱的信，在計畫階段就只列不動。
- 讀回搜尋的時間計算溢位時視為組不出搜尋；寄件人欄超過 1000 個字元視為讀不出。
- Step 9 補上：recipe 呼叫失敗就停、記錄後仍要問的寄件人不再問、answers 的鍵照 ask 清單、持續性寫入失敗的提示、照紀錄與本次同意怎麼分、不能用的條目不必手動刪。
- confirmation-protocol skill 寫明 Step 9 不在它的 bulk 觸發範圍。

## Non-Goals

- symlink 檢查的先檢查後開檔（記在 #692）、顯示名以角括號結尾的情況（#693）。

## Success Criteria

修改與新增的每條 requirement 都有 Example 與帶標記的測試；plugin 的 Python 測試全數通過。

## Impact

- Affected specs: archive-mail-junk-rescue（修改 3 條、新增 1 條 requirement）
- Affected code:
  - New: (none)
  - Modified:
    - plugin/commands/archive-mail.md
    - plugin/skills/confirmation-protocol/SKILL.md
    - plugin/tests/test-archive-mail-recipes.py
  - Removed: (none)
