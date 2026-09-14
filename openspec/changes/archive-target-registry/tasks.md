## 1. 核心

- [x] 1.1 Registry 與路徑：實作 Complete explicit target registry 的列出／驗證介面，以循環、重複、跨兄弟路徑及 CLI 測試驗證。
- [x] 1.2 跨層快照與去重：實作 Index-backed cross-layer history，以 377 index／27 md、missing/corrupt index 及多來源歷史測試驗證。
- [x] 1.3 上層捕捉與目的地：實作 Preserve independent capture and intake routing，以子層獨有、ancestor chain、跨支線歧義與既有 ID 測試驗證。

## 2. 完整執行流程

- [ ] 2.1 寫入與復原：實作 Recoverable distribution，以每個持久階段的 failure injection 與重試測試驗證不丟檔、不覆寫舊檔。
- [ ] 2.2 實作 Workflow integration and legacy compatibility，串接 SOP、registry command、schema 與完整暫存 archive 演練，驗證相容與目的地 preview。

## 3. 驗證

- [ ] 3.1 完成完整相關測試、Spectra validate 及 IDD 獨立審查；未完成 executor、SOP 或 Claude 審查不得標記 verified。
