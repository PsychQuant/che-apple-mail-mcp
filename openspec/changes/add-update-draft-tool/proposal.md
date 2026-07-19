# Proposal: add-update-draft-tool

## Why

Apple Mail 的草稿無法原地修改（scripting dictionary 無 patch/edit 草稿的路徑），而 draft-based review workflow（先建草稿供人審、內容更新後重建）目前的「改草稿」只能人工在 Mail.app 刪舊建新，且容易累積同主旨多封 stale 草稿（issue #276 的實際踩坑）。把「找舊 → 建新 → 刪舊」固化成一個 upsert 工具，比人工流程可靠且可審計。

## What Changes

- 新增 MCP tool `update_draft`：以 `identify`（`draft_id` 或精確 `subject_match`，`account_name` 選填）定位既有草稿 → 以 create_draft 全套機制重建 → 確認建立成功後刪除舊草稿（**create-then-delete**：中途失敗最壞情況是「新舊並存」可見可收拾，優於 delete-first 的「兩頭空」；與 issue 原話順序相反，資料安全優先，tool description 明示）。
- 定位歧義一律 refuse：`subject_match` 命中 0（upsert 以既有草稿為前提，不 auto-create）或 >1（含跨帳號同主旨）→ 拒絕並列出候選 `{id, subject}` 供 caller 改用 `draft_id`。
- 前置擴充 `list_drafts`：同一次 AppleScript IPC 一併回傳 `id of messages`，結果由 `[{subject}]` 變 `[{subject, id}]`（additive、零破壞）— 供 caller 取得 `draft_id`，也是 `update_draft` 內部定位的同款機制。
- 刪除複用 delete **語意**（ASCII-numeric id 驗證同 `requireMessageId` #50、AppleScript delete = 移 Trash 可救回），實作為 unified-drafts child scope 內的 delete-by-id script（同 #174 定位機制，避開 per-account 實名解析）；重建複用既有 `createDraft`（繼承 #175/#237/#239 clean-body eligibility 與揭露全套）。
- 失敗語意：create 失敗 → 不刪舊（abort throw）；create 成功但 delete 失敗 → 回 `deleted_old: false` 並明示新舊並存（不 throw — 工作已半完成）。

## Non-Goals

- 真正的 in-place 草稿編輯（平台不支援 — 本 tool 是 workaround 的固化）。
- `create_draft` 回傳新草稿 id（既有 gap，獨立 enhancement；`update_draft` 以 status string 判定成功）。
- `subject_match` 的模糊/子字串比對（誘發誤刪；只做完全相等）。
- 命中 0 時的 auto-create fallback（caller 收到 refuse 自行 create_draft 即可）。
- clean-body eligibility 的任何變更（#219/#277 的 scope）。

## Capabilities

### New Capabilities

- `draft-update`: update_draft 工具的 upsert 契約（identify 語意、create-then-delete 順序、refuse-on-ambiguity、失敗語意、揭露繼承）＋ list_drafts 的 id 欄位擴充（定位機制的前置）。

### Modified Capabilities

(none)

## Impact

- Affected specs: 新增 `draft-update`
- Affected code:
  - `Sources/CheAppleMailMCP/AppleScript/ListDraftsScriptBuilder.swift`（script 回 `{ids, subjects}` 平行 list）
  - `Sources/CheAppleMailMCP/AppleScript/MailController.swift`（`listDrafts` zip id、新 `updateDraft` orchestration）
  - `Sources/CheAppleMailMCP/Server.swift`（`list_drafts` result shape、新 tool schema + handler）
  - `Tests/CheAppleMailMCPTests/`（script-builder 單元測試 + seam 測試；遵守 #221 全文掃描禁令）
