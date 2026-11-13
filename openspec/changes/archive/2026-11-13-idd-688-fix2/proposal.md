## Problem

#688 的第 2 輪 verify 沒有 HIGH，但有三處與規格的明文抵觸：recipe 的 calls 會替不在垃圾郵件匣、或寄件人讀不出的信產生搬移參數；含 NaN、Infinity 的紀錄檔通過壞檔檢查；紀錄檔裡有巢狀過深的值時，記錄答案會丟出 RecursionError。另有 17 項較小的不一致：紀錄檔所在的目錄是 symlink 時讀寫會落到別處、bulk 規則與 Step 9 互相矛盾、搬之前的清單被寫成使用者阻止的機會、plan 的輸出帶著紀錄檔的原始內容、沒有角括號的寄件人欄其實是顯示名等。

## Root Cause

修正輪 1 把檢查放在計畫（plan_junk_rescue），產生參數的 rescue_calls 沒有重複那些檢查；loader 用 Python 預設的 JSON 解析；寫入只捕捉兩類例外；文字層新增的規則沒有對照既有的 bulk 規則。

## Proposed Solution

- rescue_calls 自己檢查 junk_path 完整相等與寄件人讀得出。
- loader 拒絕非 JSON 常數、非一般檔案、超過 4 MiB 的檔案，以及檔案或其所在目錄是 symlink 的情況；條目的鍵必須是小寫純位址、時間必須是固定的 ISO 形式。
- 寫入捕捉編碼階段的例外；plan 的輸出只帶用得到的紀錄時間。
- 信的寄件人欄沒有結尾的角括號組就視為讀不出；位址的網域要有點分隔。
- 讀回在帳號沒有垃圾桶名稱時回未確認；junk_path 沒有葉名時用路徑的末段。
- 文字：bulk 規則不適用 Step 9；清單只是揭露；記錄失敗時整批只列不動；重算後新出現的寄件人不再問；不請使用者手改條目；已知限制補上 #692、#693、#695 與 junk_path 的前提。

## Non-Goals

- 不檢查寄件人驗證（#693）、不改伺服器的搜尋（#694）、不加讀回的重試（#695）、不做端對端測試（#696）。
- 不檢查紀錄檔所在目錄以上的路徑：工作區本身可能位於連結的路徑底下。

## Success Criteria

新增與修改的每條 requirement 都有 Example 與帶標記的測試，每個測試在修正前的 commit 上失敗；plugin 的 Python 測試全數通過。

## Impact

- Affected specs: archive-mail-junk-rescue（修改 1 條、新增 5 條 requirement）
- Affected code:
  - New: (none)
  - Modified:
    - plugin/commands/archive-mail.md
    - plugin/rules/confirmation-triggers.md
    - plugin/tests/test-archive-mail-recipes.py
    - plugin/CHANGELOG.md
  - Removed: (none)
