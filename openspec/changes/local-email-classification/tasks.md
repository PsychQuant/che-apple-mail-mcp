## 1. 政策與純分類核心

- [x] 1.1 Policy 與批准：實作 Local explicit policy and approvals；驗證 schema、fingerprint、編輯失效與本機儲存。
- [x] 1.2 分類與衝突：實作 Explainable read-only classification；以合成信件驗證多規則、未分類、保護狀態及已批准 subset。

## 2. 執行契約

- [x] 2.1 Plan 與 apply：實作 Bounded plans and explicit selection；測試 expiry、stale policy/message、claim 與重複執行拒絕。
- [x] 2.2 儲存與稽核：實作 Durable minimal audit 與 Auditable policy history and no implicit retry reset；以暫存 store 驗證寫前 audit、失敗拒派及不儲存本文／主旨。
- [x] 2.3 實作 Guarded Trash movement；以 script builder／MailController seam 驗證 account/source/id/Message-ID／原生 Trash 與不確定結果。

## 3. 整合與驗證

- [x] 3.1 串接 Public tools and authorization provenance；驗證 MCP schemas、dispatch 及 plugin 明確規則批准／其餘預覽。
- [x] 3.2 執行完整測試與限定合成資料的原生 Trash 驗收：來源不符拒絕、來源一致移動、來源信箱清空、Trash 內容 digest 不變；不啟用真實規則。
- [ ] 3.3 完整 IDD 獨立審查；目前 Claude 週額度不足，不以原生邊界測試或限定 Codex 複查冒稱完整交付。空測試信箱清理另待不可還原刪除確認。
