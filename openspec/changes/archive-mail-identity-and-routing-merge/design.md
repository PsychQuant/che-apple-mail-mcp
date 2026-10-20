## Context

`/archive-mail` 的設定機制沒有集中的載入點。所謂「解析」是散在 SOP 內的 **16 條 awk 單行**，分佈於四個不同 Step，且已存在重複（`last_archived` 被 parse 兩次）。更關鍵的是設定欄位分成兩種解析模態：

| 模態 | 欄位 | 有機械掛載點嗎 |
|---|---|---|
| 機械式（awk） | `output_dir`、`last_archived`、`exclude_mailboxes`、六個 `*_includes`/`*_excludes`、`distributed_archives`、`filters`、`dedup_strategy`、`enrichment` | 有 |
| 散文式（由 agent 自行讀 YAML，無 bash） | `attachment_routing`、`subject_keywords`、`participant_aliases` | **沒有** |

本 change 要動的兩個欄位（`participant_aliases`、`attachment_routing`）**都落在散文模態**。這是所有設計決定的前提。

## Goals / Non-Goals

**Goals**
- 讓「誰是誰」有一個跨 workspace 的單一來源。
- 讓 `attachment_routing` 只需寫想改的 sub-key。

**Non-Goals**
- per-field 兩層 config（U/L/D 分類）—— 見下方 Decision 1。
- `own_addresses` 進設定檔 —— 見下方 Decision 2。
- 新增 frontmatter 欄位表達「我方是哪個帳號」—— 動到 frozen 6 欄位契約，另案。

## Decisions

### Decision 1：不做 per-field 兩層 config

原 issue 的方向是把設定拆成 user 層與 workspace 層，並為每個欄位宣告層級（user 權威／local 專屬／local 可覆寫）。**否決**。

理由是成本與收益不對稱。成本：既然沒有集中載入點，兩層意味著先把 16 條散落 awk 收斂成一處、再為散文模態的三個欄位發明 merge 掛載點；而且此後**每個新欄位都必須宣告自己的層級**，這是永久的維護稅。收益：把 issue 的三個痛點攤開後，真正需要跨層 merge 的只有 `attachment_routing` 一個 —— 另外兩個（身份資料無處可放、workspace 設定被 gitignore 擋住無法跨機器）要的是「有一個機器層級的地方存」，那不需要 merge 語意。

而 `attachment_routing` 的痛點其實與分層無關：它是「使用者設定 vs **內建預設**」的合併粒度問題，在單層內就能解。

若日後出現「某個 workspace 需要覆寫 user 層某設定」的具體案例，再引入分層不遲；屆時本 change 已把散文模態最難處理的 `participant_aliases` 移出設定檔。

### Decision 2：`own_addresses` 不進設定檔

`specs/batch-operations/spec.md` 的 requirement「Export direction derived per email from sender identity」已規定系統從 local account mapping 解析 own-addresses 聯集（無 AppleScript）。把同一份資料再寫進設定檔，等於複製一個 runtime 已解析的事實 —— 這正是本專案剛付過代價的 drift 模式（`binary_version` 在兩份 manifest 各記一份而分歧）。

已知殘留：alias 地址（plus-addressing、自訂網域轉寄）不在 account mapping 內，`export-direction-sender-identity` 的 design 已記載。目前無該情境的具體案例，不預先建設。

### Decision 3：identity 檔是「另一份檔案」，不是「config 的第二層」

`~/.claude/.mail/identity.yaml` 與 workspace config 的關係定為 **supplement**，不是 merge：identity 檔提供基底，workspace 只能新增它未涵蓋的位址；重複的條目以 identity 檔為準，並把被忽略的 workspace 條目**報出來**。

選這個而非「workspace 覆寫 identity」是因為本 change 的目的正是消除「同一個人在不同 workspace 有不同名字」。允許覆寫會把該問題原樣保留。而靜默忽略衝突則違反本專案反覆踩過的靜默失效模式，故要求顯式回報。

### Decision 4：sub-key 是 replace，不是 append

未提及的 sub-key 沿用內建預設；有寫的 sub-key 整組取代。不做 append 的理由：append 對 `data_extensions` 這類「判定集合」語意上合理，但對 `documents_dir` 這類純量無意義，兩者混在同一個區塊會需要 per-sub-key 規則 —— 又回到本 change 極力避免的 per-field 分類。統一 replace 是唯一能用一句話說完、且對六個 sub-key 都成立的規則。

代價是「停用某組預設」必須寫顯式空清單。這是 **BREAKING** 的一面：舊語意下省略即全部清空，新語意下省略是保留。

## Risks / Trade-offs

- **散文模態沒有機械驗證點。** 兩個改動都落在「由 agent 讀 YAML」的區段，無法用 shell 斷言驗證合併結果。緩解：spec 的 Example 區塊給出具體輸入與預期分類結果，實作時以那些例子當人工驗收依據。
- **BREAKING 影響面未知。** 現存 workspace 若有刻意以「省略 = 清空」寫法的 config，行為會改變。緩解：實作時掃過已知 workspace 的 config，逐一確認；本機目前唯一使用 `attachment_routing` 的 config 是完整六 sub-key 寫法，不受影響。
- **前置相依 #335。** 本 change 的目標檔案路徑是 plugin 遷入本 repo 之後的位置，且 `archive-mail-attachments` 的 base spec 仍在 aggregator。

## In scope / Out of scope

**In scope**：`plugin/commands/archive-mail.md` 的兩處設定讀取段落（附件路由設定、搜尋擴展設定），以及 `plugin/CLAUDE.md` 的 schema 區塊。

**Out of scope**：16 條 awk 解析的收斂重構（與本 change 正交，且本 change 兩個欄位都不走 awk）；四個 companion command（實測皆不解析設定）；`subject_keywords`（同屬散文模態但本 change 不動它）。

## Migration

`attachment_routing` 語意變更於實作 PR 的 CHANGELOG 條目標註 **BREAKING**，並在 `plugin/CLAUDE.md` 的 schema 區塊寫明「省略 = 沿用預設；顯式空清單 = 停用」。identity 檔為純新增，無遷移動作 —— 未建立該檔的使用者行為與今日完全相同。


## Implementation Contract

接續時以此段校正上文 2026-08-05 的環境描述：runtime own-address 探測由 binary 負責，#375 的快取並非本 change 的相依。本工作分支基於 #364 / #336 的 plugin 文件 stack。

- Step 1.4 先讀全域 identity 與已解析 CONFIG_FILE 的 workspace alias。以 trim + lowercase 的 bare email 比對，不移除 plus tag 或 dots；值必須為非空顯示字串。缺檔為空且不警告；存在但無法解析、重複 YAML key 或根節點非 mapping 時警告並捨棄該份 identity。未知頂層鍵與無效條目警告後忽略，不採用 own_addresses。
- identity 與 workspace 相同鍵時 identity 贏，具名記入 ignored_workspace_aliases（即使顯示名稱相同也揭露）；新地址才補入。這是選定的 supplement 契約，非一般 config merge。
- Phase 1 消歧義候選與 Step 7 audit 顯示共用同一 effective aliases。保留 bare email 供核對；不改 search filter、不新增 frontmatter 欄位、不把 alias 當確認授權。
- routing 每次先複製既有六個內建預設，再逐 sub-key replace；清單不 append，[] 只停用該清單，其餘 tier 保留。未知鍵、錯誤型別與空目錄字串揭露並忽略該鍵；未識別鍵不抹掉其他合法覆寫。既有附件分類順序與寫入路徑檢查照常。
- SOP 仍由 agent 解讀 YAML；不新增未串接的 parser/helper。以匿名合成 YAML 案例作文件工作流演練與獨立審查，不將參考程式的結果冒稱為實際 SOP 執行。
- 未建立 identity 檔時 alias 舊行為維持，但 routing 的省略欄位確實改變。真實歸檔的 4.2 驗收仍待辦，不能用合成案例將它勾選完成。

## 來源與前置查證

已找到原 parked artifacts，來源是另一 checkout 的 git metadata；複製回本 worktree，原副本不修改。所需 base spec 的來源為 aggregator `openspec/specs/archive-mail-attachments/spec.md`（最後改動 commit 64fecbfd09c4618a0122e973edf583a55ef95eae）；#335 雖已 CLOSED，並未在此 checkout 找到該 spec，故本 PR 帶入必要摘要。
