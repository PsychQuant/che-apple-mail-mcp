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


## 4. #586 VIP 保護

- [x] 4.1 VIP snapshot 與失效、未驗證來源不提供負向證明：實作 Fresh VIP protection for automatic Trash 的完整解析／unknown／60 秒 freshness 與 Unverified Mail source cannot prove non-VIP；以 VIPSenderSnapshotTests 驗證名單、正規化、失敗與更新。
- [x] 4.2 VIP 授權界線：VIP 與 unknown 即使已批准也保持預覽；以 ClassificationVIPProtectionTests 驗證且保留既有 flagged/draft／規則編輯失效測試。
- [x] 4.3 VIP changes invalidate pending classification：preview、refresh 與 native dispatch 前重新讀取並驗狀態；以 ClassificationPlanEngineTests 及 ClassificationToolIntegrationTests 驗證拒派、人工確認及防重派。
- [x] 4.4 macOS CI 執行回歸測試與完整 Swift suite，記錄結果；更新工具／plugin 說明，核對與 #585 無矛盾。結果見 docs/testing/classification-vip.md；完整 suite 的既有 Mail.app 相依失敗已在基底重現，不宣稱全綠或已驗證 native VIP 來源。
