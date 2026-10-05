# #488：直接寫入觸發的已讀切換間隔實驗

交易安全規則（`.claude/rules/direct-write-transaction-safety.md`）第 8 項規定：兩次已讀切換之間的 0.5 秒不是可調參數；要縮短，必須先在測試帳號上對每個候選值做至少 10 次 live 實驗。這裡是那次實驗的材料與結果。

**決定（2026-10-06，使用者）：維持 0.5 秒。** 安全優先，0.5 秒已經夠快：整次 `create_draft` 的中位數約 2.7 秒，間隔只佔其中 0.5 秒（#489 的分解）。這次實驗不改產品程式碼，也不改規則第 8 項；數據留作日後的證據。

## 檔案

| 檔案 | 內容 |
|---|---|
| `exp488.patch` | **只用於實驗**的 patch（基底 `b7d510c`）：間隔改讀 `CHE_MAIL_EXPERIMENT_488_GAP`（預設 0.5）；`ensureRead` 在補設已讀前後各寫一行 `EXP488|…` 到 stderr。**不要合進產品**：規則第 8 項禁止把間隔變成可調參數。 |
| `live488.py` | 驅動腳本：每個間隔建立 N 封草稿，記錄補設已讀前後的本機已讀狀態與上傳確認時間；一批同步完成後，記錄草稿匣與「全部郵件」各有幾份，以及「全部郵件」那份（伺服器端）的已讀狀態。 |
| `results.json` | 2026-10-06 那次的原始結果（每封一筆；工具回傳文字已移除）。 |

## 重跑方法

1. 在獨立 worktree 套用 patch，建 release binary，並用與正式版相同的 identifier 與 Developer ID 簽章（Full Disk Access 與 Automation 的授權依簽章身分判斷）：
   ```bash
   git worktree add --detach /tmp/wt488 <commit>
   cd /tmp/wt488 && git apply scripts/experiments/488-toggle-gap/exp488.patch
   swift build -c release
   cp "$(swift build -c release --show-bin-path)/CheAppleMailMCP" /tmp/CheAppleMailMCP.488
   codesign --force --options runtime --identifier CheAppleMailMCP \
     --entitlements Sources/CheAppleMailMCP/Entitlements.plist --sign "$DEVELOPER_ID" /tmp/CheAppleMailMCP.488
   ```
2. 查出測試帳號草稿匣與「全部郵件」在 Envelope Index 的 mailbox ROWID（唯讀查詢 `mailboxes`）。
3. 執行：
   ```bash
   EXP488_BIN=/tmp/CheAppleMailMCP.488 EXP488_FROM_FILE=<存有測試帳號位址的檔案> \
   EXP488_DRAFTS_MB=<草稿匣 ROWID> EXP488_ALLMAIL_MB=<全部郵件 ROWID> \
   python3 live488.py 10 results.json 0.5 0.4 0.3 0.2 0.1
   ```
4. 清除：依 ROWID 用 `delete (first message of drafts mailbox whose id is N)` 刪除探針草稿（主旨開頭 `[idd-488-probe]`），**不要用 `whose content contains`**（#221）。Gmail 會把它們移到垃圾桶；對垃圾桶郵件下 AppleScript `delete` 不會永久刪除，所以垃圾桶的副本留給 Gmail 自動清除。

## 結果（2026-10-06，Gmail 型 IMAP 測試帳號，每個間隔 10 封）

| 間隔 | 建立並確認上傳 | 補設已讀**前**本機已讀 | 伺服器端已讀 | 草稿匣／全部郵件各恰好一份 |
|---|---|---|---|---|
| 0.5 秒 | 10/10 | 10/10 | 10/10 | 10/10 |
| 0.4 秒 | 10/10 | 10/10 | 10/10 | 10/10 |
| 0.3 秒 | 10/10 | 10/10 | 10/10 | 10/10 |
| 0.2 秒 | 10/10 | 10/10 | 10/10 | 10/10 |
| 0.1 秒 | 10/10 | 10/10 | 10/10 | 10/10 |

- 間隔確實套用了：另用計時版各跑一封，`trigger_unread → trigger_read` 在 0.1 秒時量到 109 ms，0.5 秒時量到 507 ms。
- 50 封都不需要補設已讀（`after` 皆為空）。

## 怎麼讀這些數字

- **沒有重現 #472 的失敗。** #472 用 0.3 秒時兩封有一封本機留在未讀；這次 0.3 秒 10/10 都正常。原因不明：#472 那次的條件（Mail 狀態、時間點、程式版本）無法還原。
- **10 次全部成功不代表失敗率是 0。** 0/10 的 95% 信賴上限約 26%，所以這批數據排除不了「偶爾失敗」，也不足以證明更短的間隔安全。
- 補設已讀前的觀察，發生在上傳確認**之後**（至少約 1 秒後）。所以它量到的是「切換加上傳完成後」的本機狀態，不是切換那一瞬間的狀態。
- 只測了一個 Gmail 型 IMAP 帳號；一般 IMAP、iCloud 未測（#480）。

依以上限制與使用者的決定，間隔維持 0.5 秒。
