## 1. 政策與純分類核心

- [x] 1.1 Policy 與批准：實作 Local explicit policy and approvals；驗證 schema、fingerprint、編輯失效與本機儲存。
- [x] 1.2 分類與衝突：實作 Explainable read-only classification；以合成信件驗證多規則、未分類、保護狀態及已批准 subset。

## 2. 執行契約

- [x] 2.1 Plan 與 apply：實作 Bounded plans and explicit selection；測試 expiry、stale policy/message、claim 與重複執行拒絕。
- [x] 2.2 儲存與稽核：實作 Durable minimal audit 與 Auditable policy history and no implicit retry reset；以暫存 store 驗證寫前 audit、失敗拒派及不儲存本文／主旨。
- [x] 2.3 實作 Guarded Trash movement；以 script builder／MailController seam 驗證 account/source/id/Message-ID／原生 Trash 與不確定結果。

## 3. 整合與驗證

- [x] 3.1 串接 Public tools and authorization provenance；驗證 MCP schemas、dispatch 及 plugin 明確規則批准／其餘預覽。
- [ ] 3.2 執行完整相關測試與 IDD 審查，記錄真實 Mail mutation 未驗證及 Claude OAuth 缺口，不以純核心完成冒稱完整交付。
