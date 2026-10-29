## 1. 準備與內容比對

- [x] 1.1 Preserve an inert review snapshot：私有且不可覆寫的MIME審查封包保存完整輸入bytes，經fixture與CLI測試驗證。
- [x] 1.2 Compare captured versions without asserting rendering：比較來源snapshot與實收MIME內容，差異／破損輸入不放行；相同仍client_render_verified=false，經正反例驗證。
- [x] 1.3 Require actual non-Apple Mail review：command固定明確來源、capture provenance、外部寄送同意及真實客戶端觀察，經內容審查驗證。

## 2. 驗收

- [x] 2.1 離線suite／現有plugin回歸、獨立審查、Spectra analyze/validate通過。
- [ ] 2.2 以另行確認的測試帳號，在Gmail實際觀察並核對來源／實收，記錄人工結果；未取得前不標完整完成。

- [ ] 2.3 完整IDD Claude ensemble通過；目前OAuth待恢復，不能以Codex靜態審查代替。
