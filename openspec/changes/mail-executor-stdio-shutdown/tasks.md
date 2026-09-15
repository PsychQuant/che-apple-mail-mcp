## 1. 排程與測試

- [x] 1.1 Mail serial executor：Isolate blocking Mail work from stdio progress，以受限 cooperative pool 的 EOF fixture 驗證。
- [x] 1.2 Real Server probe：Verify the production lifecycle without real Mail operations，連結實際 app objects、真實 stdin pipe，驗證握手與 idle／blocked 控制組。
- [x] 1.3 Preserve Mail actor behavior，以並行呼叫、既有 timeout／write-failure／staleness 測試驗證序列性與既有語意。

## 2. 交付

- [x] 2.1 執行完整 Swift 測試、移除 executor 的反例測試及 Spectra validation，記錄命令與結果。
- [ ] 2.2 獨立 code review、完整 IDD ensemble 與 PR／issue 狀態更新；未驗證項目須明示。
