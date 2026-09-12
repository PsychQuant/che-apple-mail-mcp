## 1. 來源與快取

- [x] 1.1 Counted JSON snapshot：Read configured account identity metadata，使用 parser／script fixture 與不含私密值的原生格式探測驗證。
- [x] 1.2 Bounded shared refresh：Cache and coalesce identity refresh，以受控 clock／loader 測試 TTL、force、backoff、合併、取消與晚到完成。

## 2. 匯出與交付

- [x] 2.1 Export confidence：Preserve truthful export direction，以 EWS／alias／external／partial／failure fixtures 驗證 manifest 與推論。
- [x] 2.2 更新讀取規則例外、選項／工具描述與 manifest；以既有 export／stdio 測試及完整 Swift suite 驗證相容性。
- [ ] 2.3 Spectra validation、獨立 review 與完整 IDD ensemble；依實際證據更新 PR／issue。
