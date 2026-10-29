## 2026-09-17 ID-only baseline 與 wire 驗證

新增獨立的 `DraftIDBaseline` collector／decoder／controller read，尚未接入 create/update。它按指定帳號收集草稿 ID 聯集，不讀主旨／本文／To/Cc/Bcc；任何缺 scope 或讀取失敗都使整份結果 unavailable。正式 pre-create 呼叫順序仍依賴 2.1 的建立關聯 adapter，本次沒有勾選完成 2.3 或降低原驗收要求。

### 直接證據

- Decoder 初始 5 tests／6 failures → 5 passed；collector/controller 初始 9 tests／11 failures → 9 passed。
- 實際 AppleScript collector 的外部 Mail 邊界以固定資料代換，驗證帳號隔離、空／缺 container、多 container 聯集、中途 metadata／ID 失敗與整份拒絕。錯誤案例核對具名原因，不把語法錯誤誤算成拒絕證據。
- Codex R1 指出 Foundation 折疊重複 JSON key；2 tests／7 failures 重現，新增原始 member-name 檢查，含 escaped alias，兩個 decoder 共用。
- R2 指出 UTF-16／32 auto-detection 與 byte scanner 的編碼差異；4 個編碼變體均先錯誤通過，明訂 UTF-8／無 literal NUL 後拒絕。合法 quoted content 與 escaped NUL 保留。R3 bounded 靜態複查沒有剩餘可行動缺陷；不是完整 IDD ensemble。
- 最終 `swift test`：MailSQLite 312／1 skip，server 935／10 skip，共 **1,247 tests／11 skipped／0 failures**。
- 最終獨立 opt-in 原生唯讀測試：**1 passed，2.06 秒**；指定帳號取得 65 IDs，前後獨立 count 一致。沒有建立／修改／刪除郵件，沒有變更權限或政策；詳細重現方法見 `docs/testing/draft-id-baseline.md`。

### 未完成

ID-only baseline 不是 creation binding，前後 count 相同也不證明 ID 跨重存穩定。真正 adapter、pre-create 接線、合併三欄 receipt、刪除 gate、正常同主旨 update／competing drafts 等仍未完成。完整 Claude 角色受週額度限制，不能把本元件的 bounded review 當成整張 issue verified。

## 2026-09-17 Legacy metadata error 修正

#404 歷史 PR #407 補上的 Codex cross-model review 發現：舊 recipient scan 每筆 subject／ID 讀取錯誤被空 try/end try 吞掉，可能回 NOTFOUND 或使用較早的部分候選。現行 legacy builder 仍有此問題，因此在正式 adapter 接線前獨立修正錯誤分類：以 `RECIPIENT_METADATA_UNAVAILABLE` 與原 error number 中止整份 scan，不帶回可能含信件／帳號資料的原生錯誤文字。

實際執行生成的 metadata 控制流程，以純函式代換 Mail 存取與地址尾段：正確 RED 為 4 tests／4 failures（前兩次 harness 的縮排 anchor／reference 解參照錯誤不計）；修正後 25 項相關測試通過。涵蓋已有候選後的 subject／ID 失敗、第一筆失敗不能假報 NOTFOUND、完整 match／not-found 行為不變，以及實際 controller 將該失敗視為 unavailable 且不重試。完整 suite：MailSQLite 312／1 skip，server 939／10 skip，共 **1,251 tests／11 skipped／0 failures**。限定 Codex 複查無可行動缺陷；沒有執行新的 Mail mutation。

這只修正讀取失敗的分類。Legacy global subject／最大 ID 選擇及 update 在 unavailable 時的舊刪除策略仍未解決，不能宣稱已取得 creation binding、完成正式接線或整張 #409 verified。
