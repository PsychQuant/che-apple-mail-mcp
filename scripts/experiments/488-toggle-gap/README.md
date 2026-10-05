# #488：直接寫入觸發的已讀切換間隔實驗

交易安全規則（`.claude/rules/direct-write-transaction-safety.md`）第 8 項規定：兩次已讀切換之間的 0.5 秒不是可調參數；要縮短，必須先在測試帳號上對每個候選值做至少 10 次 live 實驗。這裡是那次實驗的材料與結果。

**決定（2026-10-06，使用者）：維持 0.5 秒。**

> 「我在想可能要安全之類的，0.5已經算快了我覺得」

理由：
- 整次 `create_draft` 的中位數約 2.7 秒，間隔只佔其中 0.5 秒（#489 的分解，計時開啟、n = 12，見 #489 的量測 comment）；
- 這批數據不足以證明更短的間隔安全（見下方「怎麼讀這些數字」）。

這次實驗不改產品程式碼；規則第 8 項只加一行指向本實驗。

## 檔案

| 檔案 | 內容 |
|---|---|
| `exp488.patch` | **只用於實驗**的 patch（基底 `b7d510c`）：間隔改讀 `CHE_MAIL_EXPERIMENT_488_GAP`（預設 0.5）；`ensureRead` 在補設已讀前後各寫一行 `EXP488|…` 到 stderr。**不要合進產品**：規則第 8 項禁止把間隔變成可調參數。 |
| `live488.py` | 驅動腳本：每個間隔建立 N 封草稿，記錄補設已讀前後的本機已讀狀態與上傳確認時間；一批同步完成後，記錄草稿匣與「全部郵件」各有幾份，以及它們在 Mail 本機索引裡的已讀旗標。 |
| `results.json` | 2026-10-06 那次的原始結果（每封一筆）。 |
| `gap-check.json` | 確認間隔有套用的兩封計時版草稿：`trigger_unread → trigger_read` 的毫秒數。 |

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
4. 清除（手動，不在腳本內）：
   - 依 ROWID 用 `delete (first message of drafts mailbox whose id is N)` 刪除探針草稿（主旨開頭 `[idd-488-probe]`），**不要用 `whose content contains`**（#221）；
   - Gmail 會把它們移到垃圾桶。對垃圾桶郵件下 AppleScript `delete` 不會永久刪除（`deleted status` 仍為 false），所以垃圾桶的副本只能留著，或在 Mail 裡手動清空垃圾桶。

## 結果（2026-10-06，Gmail 型 IMAP 測試帳號，每個間隔 10 封）

| 間隔 | 建立並確認上傳 | 上傳確認時間中位數（範圍） | 補設已讀**前**的本機已讀 | 草稿匣副本已讀 | 全部郵件副本已讀 | 草稿匣／全部郵件各恰好一份 |
|---|---|---|---|---|---|---|
| 0.5 秒 | 10/10 | 1.9 秒（1.2–3.5） | 10/10 | 10/10 | 10/10 | 10/10 |
| 0.4 秒 | 10/10 | 1.8 秒（1.1–3.8） | 10/10 | 10/10 | 10/10 | 10/10 |
| 0.3 秒 | 10/10 | 2.0 秒（1.3–2.7） | 10/10 | 10/10 | 10/10 | 10/10 |
| 0.2 秒 | 10/10 | 1.8 秒（1.3–2.7） | 10/10 | 10/10 | 10/10 | 10/10 |
| 0.1 秒 | 10/10 | 2.1 秒（1.4–4.0） | 10/10 | 10/10 | 10/10 | 10/10 |

- **間隔確實有套用**：另用計時版各跑一封（`gap-check.json`），`trigger_unread → trigger_read` 在 0.1 秒時是 109 ms，0.5 秒時是 507 ms。
- **50 封都不需要補設已讀**（`after` 皆為空）。
- **上傳確認時間**是工具回報的「觸發後多久確認上傳」，從送出上傳請求之前起算。

### 依 issue 判準的結論

issue 的通過判準有三項：最終本機為已讀、伺服器端恰好一封、沒有重複。

- **在這批樣本裡，五個間隔都達標。**
- **但 0.4、0.3、0.2、0.1 秒都不採用**，理由有兩個：
  - 每個值只有 10 封，排除不了偶發失敗（見下）；
  - 使用者決定安全優先、維持 0.5 秒。

## 怎麼讀這些數字

- **10 次全部成功不代表失敗率是 0。** 0/10 的單側 95% 信賴上限約 26%（`1 − 0.05^(1/10)`；雙側 Clopper–Pearson 上限約 31%）。
- **沒有重現 #472 的失敗。** #472 用 0.3 秒時兩封有一封本機留在未讀；這次 0.3 秒 10/10 正常。原因無法還原（當時的 Mail 狀態、時間點、程式版本）。
- **「補設已讀前」的觀察發生在上傳確認之後**（至少約 1 秒後）。它量到的是切換加上傳完成後的本機狀態，不是切換那一瞬間的狀態。
- **「全部郵件副本已讀」不是直接讀伺服器。** 它是 Mail 本機索引裡那份副本的已讀旗標，由 Mail 從伺服器同步而來，是伺服器狀態的代理；IMAP 的 `\Seen` 沒有直接讀。
- **「草稿匣副本已讀」以主旨比對。** Gmail 上傳後，Mail 可能把注入的那一列換成從伺服器抓回的那一列，所以這一欄不一定是 #472／#482 出事的那一列。補設已讀前的那一欄（`first`）才是同一列（`ensureRead` 依注入時的 ROWID 讀取）。
- **重複只在同步完成後檢查一次**，而且只算草稿匣與「全部郵件」兩個 mailbox。
- **實驗設計的限制**：
  - 間隔依 0.5 → 0.1 的順序各跑完 10 封，沒有交錯或隨機化，所以 Mail 狀態與時段的漂移和間隔混在一起；
  - 也沒有「不切換」的對照組，所以這批數據本身無法證明上傳是切換觸發的（#463 已有這方面的證據）。
- **只測了一個 Gmail 型 IMAP 帳號**；一般 IMAP、iCloud 未測（#480）。

## 清除狀態（issue 驗收第 3 項：只部分達成）

- 52 封探針（50 封實驗加 2 封確認）已依 ROWID 刪除，草稿匣與「全部郵件」都已清空。
- **垃圾桶還留著 52 封合成副本**（在 Gmail 伺服器上，所以「本機與伺服器都沒有殘留」沒有達成）：AppleScript 無法永久刪除垃圾桶郵件。要完全清除，得在 Mail 裡手動清空垃圾桶。
