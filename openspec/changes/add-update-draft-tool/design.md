# Design: add-update-draft-tool

## Context

Apple Mail 草稿無法原地修改；`update_draft` 把「找舊 → 建新 → 刪舊」固化成 upsert。設計已於 issue #276 diagnosis + spectra-discuss（unattended 單輪）收斂，本檔記錄關鍵取捨供實作與 review 引用。

## Decisions

### D1 — create-then-delete（非使用者原話的 delete-then-create）

失敗模式比較：create-first 中途失敗最壞是「新舊並存」（使用者可見、可收拾、舊資料無損）；delete-first 中途失敗是「兩頭空」（舊已刪、新未建 — 資料損失）。資料安全優先，tool description 明示與原話順序相反的理由。

### D2 — 定位歧義一律 refuse（0 與 >1 皆拒）

- `subject_match` 完全相等比對（非 substring — 模糊比對誘發誤刪）。
- 命中 >1（含跨帳號同主旨）→ refuse 並列出候選 `{id, subject}`（caller 改用 `draft_id` 精準重試）。
- 命中 0 → refuse（upsert 的 update 語意以既有草稿為前提；auto-create fallback 是 scope creep，caller 自行 create_draft）。

### D3 — id 取得走 list_drafts 擴充（同一 AppleScript IPC）

替代案「教 caller 用 search_emails scope 草稿匣」被否決：草稿匣 URL scope 有 #174 localized-name 地雷。`ListDraftsScriptBuilder` 的 unified-children 草稿匣識別（#174/#186 sanctioned AppleScript-primary）直接複用：script 一次回 `{ids, subjects}` 平行 list，zip 成 `[{id, subject}]`。`list_drafts` result shape 為 additive 變更（零破壞）。`update_draft` 內部定位同款機制。

### D4 — 複用既有語意、刪除走定位同款 scope（最小 blast radius）

刪除 = **複用 delete 語意**（ASCII-numeric id 驗證同 `requireMessageId` #50；AppleScript delete = 移 Trash 可救回），但**實作為新的 `buildDeleteDraftByIdScript`** — 在定位到草稿的同一個 #174 unified-drafts child scope 內 by-id 刪除，完全避開 per-account 草稿匣實名解析的 localized-name 地雷（比繞道 `delete_email` 的 mailbox+account 參數更穩健；verify R1 更正原「複用 delete_email 機制」的措辭）。重建 = 既有 `createDraft`（自動繼承 #175/#237/#239 clean-body eligibility 與三層揭露）。新 code 集中在一個 orchestrating handler + script-builder 擴充。

### D5 — 失敗語意不對稱

create 失敗 → throw、不刪舊（無損 abort）。create 成功後 delete 失敗 → **不 throw**，回 `deleted_old: false` + 明示「新草稿已建、舊草稿仍在」——工作已半完成，throw 會誤導 caller 以為全失敗。

## Risks

- 重建後草稿是**新 id** — caller 不可沿用舊 id（tool description 明示）。
- 帶 display-name 收件人或 `from_address` 的重建落 legacy path（body 被 wrap）——與 create_draft 同款揭露，`require_wrapper_free` 同樣可用。
- 草稿匣定位是 AppleScript-primary（#186 sanctioned exception），延遲可接受（草稿數少）。
- Tests 遵守 #221：定位/清理一律 id/subject 比對，絕不 `whose content contains`。
