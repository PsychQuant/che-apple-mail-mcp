## Why

`/archive-mail` 產出的歸檔目前**看不懂人**。frontmatter 只有 `sender: oxalislin@ntu.edu.tw`，讀者得自行知道那是誰；而唯一能記錄「誰是誰」的 `participant_aliases` 綁在單一 workspace 的 config 內，於是同一位 collaborator 在不同 workspace 會有不同別名、或根本沒有。

同時，`attachment_routing` 的「partial override 取代整組預設」語意造成一個反覆出現的摩擦：只想新增一個 keyword，也必須把 `data_extensions` / `document_extensions` / `data_keywords` / `document_keywords` 四組清單完整複製一份。2026-08-05 一次實際歸檔就為了讓一個 `.xlsx` 公文附件不被誤判為研究資料，複製了整組再加兩個詞。

原始需求（使用者原話）是「我要知道收件人是誰、我的哪一個信箱是什麼」。本 change 處理第一個問句與上述附件摩擦；第二個問句需動到 frozen frontmatter，另案處理（見 Non-Goals）。

## What Changes

- **新增 machine-global 身份檔** `~/.claude/.mail/identity.yaml`，承載 `participant_aliases`。它**不是 config 的第二層** —— 沒有 merge 語意、沒有 workspace 版本可以覆寫它，因為「誰是誰」跨 workspace 恆定。
- workspace config 的 `participant_aliases` 維持可用但降為**補充**：identity 檔提供基底，workspace 只能新增該檔未涵蓋的條目，不得改寫既有條目。
- **`attachment_routing` 由 all-or-nothing 改為 sub-key merge against 內建預設**。未提及的 sub-key 沿用內建預設；有寫的 sub-key 整組 replace（非 append）。**BREAKING**：既有 config 若刻意依賴「省略某組清單即停用」的寫法，行為會改變 —— 需以顯式空清單表達。
- 兩份文件同步：SOP 的設定說明與 plugin CLAUDE.md 的 schema 區塊。

## Non-Goals

- **per-field 兩層 config（U/L/D 分類）** —— 原 issue 的初始方向，經討論放棄。代價是永久維護稅（此後每個新欄位都要宣告層級），而拆解後真正需要跨層 merge 的只有 `attachment_routing` 一個，且可在單層內解決。若日後出現「某 workspace 需覆寫 user 層」的具體案例，再加分層不遲。
- **`own_addresses` 進 config** —— 已由 binary 解決。`specs/batch-operations/spec.md` 的 requirement「Export direction derived per email from sender identity」規定系統從 local account mapping 解析 own-addresses 聯集，無需 config。把它寫進 config 等於複製一個 runtime 已解析的事實，正是本專案剛踩過的 drift 模式。
- **alias 地址（Gmail plus-addressing、自訂網域轉寄）的 own-address 補充** —— `export-direction-sender-identity` 的 design 已將其列為已知殘留。目前無該情境的具體案例，不預先建設。
- **frontmatter 增補「我方身份」欄位** —— 回答使用者第二個問句（「我的哪一個信箱」）需要新的 frontmatter 欄位，動到 6 欄位 frozen 契約，成本與本 change 不同量級，另開 issue。
- **companion commands** —— 實測 `archive-mail-view` / `archive-mail-rebuild-threads` / `archive-mail-repair-synthetic-ids` 完全不讀 config，`archive-mail-migrate` 只搬檔案不解析。本 change 不觸及它們。

## Capabilities

### New Capabilities

- `archive-mail-identity`: machine-global 身份資料的來源與解析規則 —— 檔案位置、與 workspace config 的優先序、缺檔時的行為。

### Modified Capabilities

- `archive-mail-attachments`: `attachment_routing` 的 override 粒度由整個物件改為 sub-key。

## Impact

- Affected specs: `archive-mail-identity`（新增）、`archive-mail-attachments`（修改）
- Affected code:
  - New: (none) —— identity 檔由使用者在自己 home 目錄建立，非 repo 內檔案
  - Modified:
    - plugin/commands/archive-mail.md
    - plugin/CLAUDE.md
  - Removed: (none)

**前置相依**：上述兩個 Modified 路徑是 issue #335 遷移**之後**的位置。本 change 的實作必須在 #335（plugin shell 遷入本 repo）落地後進行；`archive-mail-attachments` 的 base spec 目前仍在 aggregator，隨 #335 一併遷入。


## 2026-09-14 接續校正

#335 已落地，plugin 路徑存在。原 parked 副本取回後依 #336 的完整 schema 接續；`archive-mail-attachments` 的原 base 摘要由 aggregator 擷取，本 change 新增的具名 override requirement 改用 ADDED（原 base 沒有同名 requirement）。既有摘要本身保留。

`email-search-disambiguation` 實際讀 alias 候選，因此納入同步範圍；四個 companion commands 仍不改。#375 已有 runtime configured identity cache，但未合併；無論哪版 runtime，本 change 均不新增 own_addresses 設定。這些更新不恢復先前否決的 U/L/D 方案。
