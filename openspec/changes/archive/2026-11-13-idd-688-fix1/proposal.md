## Problem

#688 的第 1 輪 verify 找到 6 項會讓救回這一步做錯事的缺陷：寄件人位址取到顯示名裡的位址（可以冒用已記錄的寄件人）；讀回把任何不是垃圾郵件匣的匣都當成已救回、不驗帳號、漏掉讀不全的列；讀回的搜尋沒有範圍，固定主旨的通知信每次都回未確認；Step 9 沿用 Step 7 算好的計畫，紀錄檔之後被改或變壞都不影響它；紀錄檔的條目不驗 version、時間與重複鍵；Step 3 替沒有 account_id 的搜尋結果補值。另有 18 項文字與邊界的不一致。

## Root Cause

第一版的 recipe 把寄件人欄當成「位址在第一組角括號」、把讀回當成「主旨相同的列」，沒有對照伺服器實際的輸出與搜尋的預設上限；計畫只算一次；紀錄檔只檢查形狀。

## Proposed Solution

- 寄件人位址取字串結尾的那一組角括號；顯示名帶角括號或另一個位址、位址不是 ASCII 時視為讀不出。
- 垃圾郵件匣的判定要有 junk_path 而且完整相等；葉名相同的另列不搬；判定不了的信一律計數。
- 三個呼叫的參數由 recipe 產生；收件匣查不到、信叫不動、讀回組不出來的信在計畫階段只列不動。
- 讀回的搜尋綁帳號與收信時間前後一分鐘；只有同帳號、不在垃圾郵件匣與垃圾桶的完整相符列算證據；move_email 回報錯誤時照樣讀回。
- Step 9 開始時與記下答案之後各重算一次計畫。
- 紀錄檔：version 必須是 1.0、條目要有帶 offset 的時間、重複鍵與 symlink 都只列不動；照紀錄搬的信先列出來；寫入失敗一律回錯誤名稱。
- 拿掉 account_id 的補值。文字同步：Step 8.5、Step 7 的失敗處理、已登錄目標不在範圍、Provenance 第 2、3 類不授權這個搬移。

## Non-Goals

- 不處理已登錄目標的 tree 流程（#690）、預授權的機械收窄（#691）、紀錄檔的鎖（#692）。
- 不驗證紀錄檔是誰寫的：做不到，規則與 SOP 照實寫。

## Success Criteria

新增與修改的每條 requirement 都有 Example 與帶標記的測試；每個測試在修正前的 commit 上失敗。plugin 的 Python 測試與 Swift 的鎖定測試全數通過。

## Impact

- Affected specs: archive-mail-junk-rescue（修改 2 條、新增 9 條 requirement）
- Affected code:
  - New: (none)
  - Modified:
    - plugin/commands/archive-mail.md
    - plugin/rules/confirmation-triggers.md
    - plugin/tests/test-archive-mail-recipes.py
    - plugin/CLAUDE.md
    - plugin/CHANGELOG.md
  - Removed: (none)
