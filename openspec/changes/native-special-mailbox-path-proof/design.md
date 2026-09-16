## Context

舊 joiner 的同父層票數不是角色證據。原生探測已有 40 個正向、40 個錯誤角色及 12 個跨帳號同名反向控制；目前沒有同帳號不同父層的同名實例，不能宣稱已做該實機測試。

## Goals / Non-Goals

**Goals:** 只有原生確認的唯一候選可成為 `_path`，普通同名資料夾不能自我佐證。

**Non-Goals:** 不恢復 #268 的 vacuous container walk；不修改資料夾、不掃描郵件、不改 unified／leaf／account ambiguity 契約。

## Decisions

### Candidate discovery

以 role leaf 與索引的 path_components 產生有序候選。名稱只用於發現，不能授權回傳。空元件／NUL／字面 slash 的元件不回傳為現有 string `_path`，不重新拆解有損字串。

### Native comparison

一次非 GUI script 為各 role 重新尋找 canonical account 的 unified child，要求恰好一個且目前名稱符合預期，再以精確 component chain 解析候選，對候選與原生 role 物件分別逐一檢查固定數量的 native container 名稱，最後必須到達指定帳號，再比較 Mail 物件。不能用 class == mailbox 的 while 迴圈，因為 native parent 可能回報 container class；固定深度檢查不會 vacuously 成功。固定 JSON version/count/results，每個 index 恰好一筆 available/matches boolean；格式或對應錯誤拒絕整份證據。使用既有 Automation grant 與現有 timeout/reaping 機制。

### Evidence-only output

每個 role 恰好一個 confirmed candidate 才輸出；多個 true 省略，未確認值不算證據。native probe 或 index 失敗保留 leaf 並記診斷。舊 path tuple 尾段一律忽略，防止繞過新閘門。無 candidates 不啟動額外 script。

## Implementation Contract

`get_special_mailboxes` 參數與 leaf/unified 結果不變；optional `_path` 的信任條件改為原生確認。候選與回應 index 綁定，未知 role、重複／遺漏／越界 index、非 boolean、版本／筆數不符都不能回傳路徑。普通 `Projects/Drafts` 與 `Projects/Sent` 即使彼此相鄰，也必須取得各自的原生角色證據。

驗收包含上述反例、top-level／nested 正常控制、模糊候選、literal slash、舊 tuple、controller seam、產生器與 native read-only controls，以及完整 Swift suite。

## Risks / Trade-offs

原生驗證增加一次 metadata 操作（內含多個 Apple Events）→ 非逐封訊息工作、有 timeout，失敗僅省略 path。設定可能在兩次讀取間改變 → 重新確認 leaf／account，不宣稱跨來源原子快照。現有 string path 無法表達元件內 slash → 保留 leaf，省略 path。

## Migration Plan

提交 PR，維持 consumer 的 absent-path fallback。未授權不部署或合併。

## Native evidence update

Direct references expose usable container names even when their reported class is container rather than mailbox. A fixed-depth component check plus final account-object equality passed all 40 recorded positive cases. The live fixture also includes 40 nonexistent candidates and 20 invalid top-level shorthands. A generated-script control retains the same real mailbox reference but changes the expected ancestor: the native role still exists, yet all candidates are rejected by the chain guard. This addresses name-selector normalization risk without creating user folders.

Per-account leaf metadata now uses JSON over the existing non-GUI subprocess transport; the former in-process list query did not finish in the MCP observation window. Unified mode remains unchanged. Cold standalone helper probes showed intermittent availability before app context initialization; this is recorded separately from object/path correctness.
