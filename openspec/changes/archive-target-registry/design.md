## Context

組織父子關係不等於檔案路徑祖先。上層與子層 filter 可交錯，保留每層候選搜尋，收斂為同一組織樹的 capture/dispatch 工作。原問題的 377 index／27 md 差額不能因掃不到 md 就從去重集合移除。

## Goals / Non-Goals

**Goals:** 完整列出目標、顯式階層、index tombstone 去重、上層 intake、跨層分派與中斷復原。

**Non-Goals:** 不要求父 filter 包含子 filter、不自動掃描或註冊整台機器、不把 alias 與 registry 混在同一檔、不推導真實 archive 路徑、不操作真實 Mail 作開發測試。

## Decisions

### Registry 與路徑
使用 JSON version 1 + targets 陣列；每個 target 具 id、parent_id（根為 null）、workspace、config_file、output_dir、index_file、purpose、filter_axis。workspace 與三個檔案／目錄路徑均採絕對路徑；canonicalization 後不可共用 config、output 或 index。parent 集中宣告且不可循環。所有父節點的 output_dir 即其 intake，不從目錄名稱判斷角色。

### 跨層快照與去重
以指定目標的 root 為 scope，讀完整樹所有 indexes。要求 version 1.0、emails mapping 與合法 Message-ID／entry；缺少或損壞任何 scope 內的 index 即拒絕進行不完整去重。新目標需明確初始化空 index，缺檔不是空歷史。其他不相關樹的失效路徑在 inventory 揭露，但不參與此樹去重。

保留 registry 與各 index 的 SHA-256 快照。每個 ID 記錄所有來源，不靜默挑 owner；index-only entry 標示 historical_index_only，照樣阻擋重抓，但不聲稱知道檔案去向。分派新增明確 destination 與 journal，避免新資料再靠猜測 tombstone。

### 上層捕捉與目的地
暫採向使用者建議的各層搜尋／root intake 統一捕捉方式（尚未收到相反回覆）；filter_axis 是說明資料，不是可執行搜尋字串。各層依自己的 config 搜尋，候選先去重，再於預覽列出命中規則、capture root、目的地。規則的 matched_target_ids 是已確認判準的結果，registry 不能憑地址／路徑自行認定分類。

唯一匹配或同一 ancestor chain 取最深匹配；跨支線匹配留在最低共同祖先 intake，未匹配留 root intake。子層獨有候選仍為 new，不能因父 filter 未命中而丟棄。既有 ID 回報 already_archived + locations，不重新 capture；既有 intake 的再次分派是明確選取舊項目的另一個動作，不借新信 capture 重寫。

### 寫入與復原
全範圍交付需有可重驗的 plan、journal 與同樹操作鎖。套用前重驗 registry/index 快照，變動即要求重規劃；不得把只讀 planner 當寫入鎖。先完成 intake markdown + index，再完成目標 markdown、附件與 index；核對 Message-ID、內容與附件後，才把來源 entry 記為 distributed tombstone 並清除本輪擁有的 intake 副本。目的地失敗保留 intake，journal 留待重試。來源舊檔、無法證明本輪擁有的副本不可自動刪除。

跨 filesystem 沒有多檔原子提交，必須以狀態機重入；不得以單一 rename 冒稱跨 index 原子性。尚未有上述 executor 與 SOP 串接時，registry/planner 只能標為基礎實作，不能標示 issue 已完成。

## Implementation Contract

`plugin/scripts/archive_registry.py` 提供 importable Registry + Snapshot + plan 與 JSON CLI；輸入錯誤為具 target 的結構化 error，非零 exit，CLI 不寫入 registry／archive。schema 嚴格檢查 unknown keys、bool 當 version、重複 ID、canonical 路徑共用、dangling parent、cycle。snapshot 讀 index keys 不是掃 md 當去重來源；md 存在與否只是位置證據。

後續 executor / SOP 的接受條件包括 failure injection：目的地成功前、目的地 index 成功後、來源 tombstone 後中斷皆可復原且不重抓／不丟檔。既有未註冊使用者及外部 distributed_archives 保持相容，但 scope 內同一 target 不由兩套來源互相猜測。core 測試不能代替 executor／SOP 驗證。

## Risks / Trade-offs

- registry 路徑改名會 stale → 列出目標錯誤，scope 內停止；不自動改指向。
- legacy index-only 是歷史證據、不是檔案存在證據 → 明確揭露，不自動重抓補檔。
- 舊 workflow 不懂新樹鎖 → 新 workflow 執行時需避免並行 legacy 寫入，並以快照重驗偵測已知衝突；完整 executor 必須留下誠實限制。
- Claude OAuth 過期 → 先完成可執行測試與 Codex 審查，完整驗證 gate 保留。
