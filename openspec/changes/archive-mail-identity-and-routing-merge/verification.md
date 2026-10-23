## 驗證紀錄（2026-10-23，取代 2026-09-14 的「尚待完成」）

### 真實歸檔驗收（tasks 1.1–1.3、2.1–2.3、4.2）

以使用者既有的一個 workspace（config、index、threads 與已歸檔 md）複製三份副本（2026-10-23，Asia/Taipei），用真實 Mail 跑 `/archive-mail`。Mail 只讀；每個 agent 只使用讀取與匯出工具；真實 workspace 沒有任何檔案變動。結果摘要（地址已改成代號）在 `evidence/real-archive-2026-10-23.json`。

- **A（改版前 SOP）vs B（改版後 SOP），沒有 identity 檔**：兩邊都歸檔同一組 12 封新信、跳過 2 封既有信；md 檔逐位元相同，index 40 筆相同，thread 36 個相同（只差頂層更新時間），附件 0／0，coverage audit 都是 12 個 thread 全部完整。B 的報告沒有任何缺檔字樣。→ 4.2、1.1 通過。限制：這個 workspace 沒有 alias、四個清單都寫出，新信也沒有附件，所以新規則在 A、B 都沒被觸發。
- **C（改版後 SOP），暫時 identity 檔 + 副本設定改動**：identity 檔的路徑是固定的，無法指向副本，所以這次直接建立了真正的 `~/.claude/.mail/identity.yaml`（約 18 分鐘），執行後刪除並確認不存在。這段時間若有其他 workspace 的 `/archive-mail` 在跑，也會讀到這份測試用別名；就我們所知當時沒有，但無法完全排除。結果與執行前寫下的預期逐項相符：
  - identity 獨有的地址以 identity 的名稱呈現（1.2）；identity 與 workspace 都有的地址採 identity 的名稱，workspace 那筆列入 `IGNORED_WORKSPACE_ALIASES` 並在報告具名揭露（1.3）；workspace 獨有的地址照用；不是 email 的 workspace 鍵原樣保留、只警告一行，警告不含顯示名稱（Decision 5-2）。
  - 部分 routing：重新歸檔一封帶兩個 PDF 附件的既有信。檔名含使用者 keyword 的那個 PDF 由使用者寫的 `data_keywords` 命中（不分大小寫）→ data；另一個 PDF 落到沿用的內建 `document_extensions`（pdf）→ document；拼錯的 `data_dirs` 具名警告且沒有建立目錄；沒給值的 `document_keywords` 視為停用並揭露（2.1–2.3、Decision 5-1、5-4）。
  - Phase 1 乾跑：只有全域 identity 命中的模糊人名，即使 `--no-confirm` 仍列候選、不標推薦；地址也在本 workspace thread participants 的名字可直接採用（Decision 5-3）。
- **沒有涵蓋**：「使用者清單勝過沿用的預設」在這批真實附件上沒有可區分的檔名（沒有一個附件會被沿用的預設搶走），只由 spec 的兩個 scenario 涵蓋。

### 盤點（task 4.1）

掃描家目錄與雲端同步資料夾：17 份 config，可讀的 10 份都不受 routing 改動影響，2 份有 alias 也照原樣保留；7 份雲端佔位檔讀不到內容，未判定（`evidence/config-inventory-summary.json`）。2026-09-14 的盤點只掃了 `~/Developer`，漏掉 proposal 引用的 workspace。

### 審查後的取捨

2026-10-22 使用者依六角色審查的發現決定四個取捨，記在 design.md Decision 5；SOP、spec、CLAUDE.md、skill 與 CHANGELOG 已同步。

### 2026-09-14 合成演練的效力

evidence/ 裡的 `cases.json`、`expected.json`、`agent-replay.json` 是 2026-09-14 依當時 SOP 做的文字演練，早於 Decision 5，其中正規化重複、workspace 條目丟棄等案例的預期已不適用。保留作為歷史紀錄；驗收以上面的真實歸檔為準。

### Spectra 驗證的注意事項

在這個 worktree 內執行 `spectra validate`／`analyze` 時，CLI 解析到的是主 checkout 與 park 區的舊副本，不是 worktree 的檔案（新增一個測試用 change 會回報 not found）。2026-10-22 起改為把 `openspec/` 複製到獨立暫存 repo 驗證：`validate` 通過，`analyze` 無 Critical／Warning。2026-09-14 紀錄的 Spectra 結果因此無法確認是針對本 change 的檔案。

### 驗證中發現、與本 change 無關的問題（已開 issue）

- #536：多個工具呼叫同時進來時，SQLite 連線陷入活鎖，server 滿載 CPU 卻不回應。
- #537：server 啟動時開不起索引就永遠不再重試；`check_fda` 卻回報已授予。
- #538：`text/plain` 宣告 US-ASCII 但內容是 UTF-8 時，匯出內文變成亂碼。

## 驗證紀錄（2026-09-14）

- 實作為出貨的 agent SOP／schema 文件，沒有新增未串接的程式 helper 或 Swift runtime 改動。
- `python3 plugin/tests/test-archive-mail-recipes.py`：21 項全部通過，確保既有路徑／日期 recipe 保持可用。
- Codex 依修改後 SOP 解讀 15 組匿名 YAML 情境；結果與事先寫定的 alias、忽略清單、警告、分類及完整六欄 routing 預期相符。這是文字工作流演練，不是真實 Mail 歸檔。輸入與輸出保存在 evidence/。
- Codex 獨立靜態審查 PASS，未找到阻擋缺陷；reviewer 沒有執行測試或真實歸檔，不能算成六方 PASS。
- `spectra analyze` 無 Critical / Warning；`spectra validate` 通過。原本 base spec 缺失與兩個否決決定的對帳缺口已消除。
- 只讀盤點 Developer 底下已知 config.yaml/config.md：找到 1 份、routing 六欄完整且型別有效；這份不受省略語意改動影響。全域 identity 檔不存在。沒有修改或公開使用者設定內容。

## 規格來源

原 change 從另一個 checkout 的 Spectra 暫存目錄複製回本 worktree，原副本未修改；採 issue Discussion Conclusion 與 Errata，未恢復被否決的 U/L/D 方案。原 artifact 內的環境敘述保留，接續校正另段記錄。

base spec 從 `PsychQuant/psychquant-claude-plugins` 的 `openspec/specs/archive-mail-attachments/spec.md` 擷取，該檔最後改動 commit 為 64fecbfd09c4618a0122e973edf583a55ef95eae。摘要原樣保留；本 change 的新具名 requirement 用 ADDED。

Base SHA-256: `0b94ae6b4f2be114f592febab54e4795aa7e54bf2f7a0814c7090ba4a9ea1e29`
