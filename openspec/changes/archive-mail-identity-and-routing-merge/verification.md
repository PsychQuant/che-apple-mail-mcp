## 驗證紀錄（2026-09-14）

- 實作為出貨的 agent SOP／schema 文件，沒有新增未串接的程式 helper 或 Swift runtime 改動。
- `python3 plugin/tests/test-archive-mail-recipes.py`：21 項全部通過，確保既有路徑／日期 recipe 保持可用。
- Codex 依修改後 SOP 解讀 15 組匿名 YAML 情境；結果與事先寫定的 alias、忽略清單、警告、分類及完整六欄 routing 預期相符。這是文字工作流演練，不是真實 Mail 歸檔。輸入與輸出保存在 evidence/。
- Codex 獨立靜態審查 PASS，未找到阻擋缺陷；reviewer 沒有執行測試或真實歸檔，不能算成六方 PASS。
- `spectra analyze` 無 Critical / Warning；`spectra validate` 通過。原本 base spec 缺失與兩個否決決定的對帳缺口已消除。
- 只讀盤點 Developer 底下已知 config.yaml/config.md：找到 1 份、routing 六欄完整且型別有效；這份不受省略語意改動影響。全域 identity 檔不存在。沒有修改或公開使用者設定內容。

## 尚待完成

原 tasks 1.1–1.3 的實際歸檔報告驗收及 4.2 的真實歸檔回歸仍未完成；Claude OAuth 尚未登入，四個 lens + DA 保留待辦。PR 必須維持草稿，不建立 verified tag、不合併或結案。

## 規格來源

原 change 從另一個 checkout 的 Spectra 暫存目錄複製回本 worktree，原副本未修改；採 issue Discussion Conclusion 與 Errata，未恢復被否決的 U/L/D 方案。原 artifact 內的環境敘述保留，接續校正另段記錄。

base spec 從 `PsychQuant/psychquant-claude-plugins` 的 `openspec/specs/archive-mail-attachments/spec.md` 擷取，該檔最後改動 commit 為 64fecbfd09c4618a0122e973edf583a55ef95eae。摘要原樣保留；本 change 的新具名 requirement 用 ADDED。

Base SHA-256: `0b94ae6b4f2be114f592febab54e4795aa7e54bf2f7a0814c7090ba4a9ea1e29`
