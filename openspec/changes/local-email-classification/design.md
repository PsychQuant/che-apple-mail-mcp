## Context

使用者的後續 Decision 已取代「不要自動處置」建議。規則可由 LLM 協助草擬，但批准必須來自使用者；執行層採確定性比對，不靠 LLM 臨時判斷信件是否該丟掉。

## Goals / Non-Goals

**Goals:** 自訂分類、本機可讀判準、每封可解釋結果、明確批准規則 auto-trash、其餘預覽、可稽核處置。

**Non-Goals:** 不清空 Trash、不訓練模型、不持久化本文、不自動從第三方 config 匯入批准、不建立背景排程、不在開發測試移動真實郵件。

## Decisions

### Policy 與批准
固定 `~/.claude/.mail/classification-policy.json`。version 1；categories 含 id/label，rules 含 id/category/conditions/action/enabled。conditions 為 AND，支援 sender equals、subject equals/contains、list_id equals；不支援 body 或任意 regex／程式碼。action 為 keep/review/trash。保留 unclassified/conflict 系統結果。

auto-trash approval 綁定每條規則完整 canonical JSON 的 SHA-256；規則改動或停用即無效。configure tool 只在 caller 明確傳入已批准規則 IDs 與確認聲明時建立批准。聲明不是人類身分驗證，plugin 仍需遵守來源授權；郵件內容、引用段落、模型自己產生的 flag 都不是批准。沒有真實規則批准以前，這次「實作功能」授權不會替使用者啟用任何清理判準。

### 分類與衝突
規則匹配回傳 category/action、匹配 rule IDs 與固定理由。多條命中但 category/action 不一致時為 conflict，只預覽；一致時保留全部 rule IDs。至少一條匹配且仍有效的批准可讓 trash 自動執行；所有結果仍附理由，不輸出沒有校準依據的機率。

沒有命中回 unclassified/review。draft、flagged 或 draft 狀態未知時不自動處置，結果說明保護原因；使用者看過後仍可明確選定 ids。無可驗證原始身分的信不交給 apply，避免 rowId 重用造成誤動作。

### Plan 與 apply
classify_emails 只讀 Mail，產生記憶體 plan（TTL 300 秒、最多 200 個 unique ids）。apply_email_classification 接受 plan_id + 精確 ids，沒有 predicate。自動分支限已批准 trash 規則，其餘需本次明確 confirmed-preview 聲明。整個選取先驗證，才 claim items；已開始／已完成／unknown 不可重試。

執行前讀最新 policy digest 與信件快照，檢查 account、mailbox components、numeric id、RFC Message-ID、分類所依據欄位和保護狀態。native script 再以 account UUID、完整 source chain、id + Message-ID 定位，唯一 native Trash role 才 move；已在 Trash 不 delete。結果只在原生明確回傳時視為成功，timeout／失聯標 outcome_unknown，必須重新查實際 Mail 狀態。

### 儲存與稽核
Store 固定本機 namespace，測試注入暫存目錄；policy 原子寫入、權限限制、symlink／可被其他使用者寫入的檔案拒絕。read 缺檔回空 policy，不自動批准。audit 在動作前持久寫入 started，之後寫 succeeded/refused/outcome_unknown；只記 id、Message-ID hash、rule/category、來源與結果，不含 subject/body。audit 失敗即不開始 move；結果落盤失敗須揭露，不能重試原動作。

## Implementation Contract

公開 tools：get_email_classification_policy、configure_email_classification、classify_emails、apply_email_classification。configure 只存 policy／批准，不改 Mail；classify 不改 Mail。empty policy 仍回 unclassified/review，plugin 可協助設定判準，不默默加垃圾桶規則。

錯誤包括 invalid policy、unknown category/rule、未批准／未確認、plan expired、policy changed、message changed、already attempted、audit unavailable、native destination ambiguous。batch 回傳每個 id 的處置結果，不把部分成功報為全成功。SQLite／.emlx 不可用時拒絕不完整的自動處置，不改走模糊帳號或 body heuristic。

core/store 單元測試不等於完整工具已交付。必須完成 MCP schema/dispatch、plan engine、native guarded move 與 plugin flow，再做完整相關測試和獨立審查。

## Risks / Trade-offs

- Mail／SQLite 狀態可能延遲：重驗與 native guard；無法證明時不動作。
- move timeout 無法證明是否已執行：audit unknown、消耗該 item，禁止自動重試。
- local approval 是 caller 已取得使用者批准的契約，不宣稱防得住有同一 OS 權限的惡意程式。
- Claude OAuth 與原生 mutation live gate 待補，不能以 seam PASS 冒稱真實移動驗證。


## Core／store 接續細節

plan 的 policy digest 必須涵蓋整個 envelope（policy + approvals），不能只雜湊規則，否則撤回批准後舊 plan 仍可能執行。configure 支援明確 approving／revoking IDs；未變動規則可保留原批准，變動／停用／移除則清掉。subject 條件的前後空白有意義，不能自動去除；sender／List-ID 則存標準化值。

store 以固定 namespace directory fd、nonblocking flock、owner-only regular single-link 檔案及原子 rename 寫入；audit 先檢查前一筆 newline 邊界，partial tail 拒絕新增以免掩蓋中斷。初次 policy 缺檔回空值，不建立偏好檔。

apply 只執行 plan 中 proposed action 為 trash 的選取項；keep/review/conflict 本身不是垃圾桶處置意圖，不能靠 confirmed=true 改成 trash。這些項目保持預覽，若使用者另選其他處置，沿用既有明確目的地工具。


分類快照亦帶 RFC 原始內容的 SHA-256（不帶本文），用於 apply 前偵測同 Message-ID 的內容變動；沒有內容 digest 不能自動處置。read-only decision 回傳 subject/sender 供人類預覽，但 audit 型別不包含這兩欄，避免把預覽快照直接寫入稽核檔。


核心審查後收緊兩個邊界：production 從解析後的可信 home fd 起，逐層 openat + O_NOFOLLOW／mkdirat 開啟 namespace，不能透過 .claude 的祖先 symlink 讀入外部批准。Message-ID 的自動處置身分採保守 ASCII dot-atom@dot-atom 子集合；quoted／obsolete／格式錯誤保持預覽，不宣稱提供完整 RFC parser。


FD traversal 的實作保留 directory 的原始 path，不呼叫 Foundation.standardizedFileURL：macOS 會把已存在的 /private/var 測試路徑縮成 /var symlink，造成正當重讀被 no-follow 擋住。測試注入路徑的既存根用 POSIX realpath 取得；production 仍從可信 home fd 逐層開 namespace。dot traversal 明確拒絕，不用路徑標準化掩蓋 symlink。
