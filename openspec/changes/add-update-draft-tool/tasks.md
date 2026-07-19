# Tasks: add-update-draft-tool

## 0. Design 對照（design.md topics → tasks）

- D1 — create-then-delete（非使用者原話的 delete-then-create）→ task 2.3 (b)(c)
- D2 — 定位歧義一律 refuse（0 與 >1 皆拒）→ tasks 2.2、2.3 (a)
- D3 — id 取得走 list_drafts 擴充（同一 AppleScript IPC）→ tasks 1.1–1.3
- D4 — 全數複用既有機制（最小 blast radius）→ task 2.3 (b)(c)
- D5 — 失敗語意不對稱 → task 2.3 (c)(d)

## 1. list_drafts id 擴充（spec Requirement: list_drafts returns draft ids；design D3）

- [x] 1.1（spec: list_drafts returns draft ids — id and subject pairing）`ListDraftsScriptBuilder.buildListDraftsScript` 改回傳 `{ids, subjects}` 平行 list（同一 `tell` 區塊：`get {id of messages of mb, subject of messages of mb}`；維持 #174 unified-children 草稿匣識別與既有 no-match error 契約）。TDD：script-builder 單元測試先行（script 文字含 id 取用；既有 golden 斷言更新）
- [x] 1.2 `MailController.listDrafts` 解析平行 list、zip 成 `[{"subject": s, "id": i}]`（`runScriptAsList` 或等價解析；兩 list 長度不一致 → throw 明確錯誤不靜默截斷）。TDD：seam 測試（scriptRunner 注入固定回傳）
- [x] 1.3 `Server.swift` `list_drafts` handler 與 tool description 更新（result shape 揭露 additive `id` 欄位；spec: list_drafts returns draft ids — backward compatibility scenario）

## 2. update_draft tool（spec Requirements: update_draft upsert tool + identify selector semantics；design D1/D2/D4/D5）

- [x] 2.1 `Server.defineTools()` 新增 `update_draft` schema：`draft_id` | `subject_match` 二擇一必填（描述明示互斥）、`account_name` 選填、其餘沿 `create_draft` 參數（to/subject/body/cc/bcc/attachments/from_address/format/sanitize_links/require_wrapper_free）；description 明示 create-then-delete 順序（與 delete-first 的資料安全理由）、重建後新 id、legacy-path 繼承揭露
- [x] 2.2 handler 參數驗證（spec: identify selector semantics — both/neither selector scenario；design D2）：兩 selector 都給或都缺 → invalidParameter；`draft_id` 走 `requireMessageId` 同款數字驗證。TDD：validation 測試先行
- [x] 2.3 `MailController.updateDraft` orchestration（spec: update_draft upsert tool 全部三 scenario + identify selector semantics 的 refuse 兩態；design D1 create-then-delete / D2 refuse / D4 複用 / D5 失敗語意）：(a) 以 1.x 的 list 機制定位（`draft_id` 直接比對 id、`subject_match` 完全相等比對 subject）；命中 0 → refuse（明示 update 需既有草稿）；>1 → refuse 列候選 `{id, subject}`；(b) 呼叫既有 `createDraft`（繼承 eligibility/揭露）；(c) create 成功才以既有 delete 機制刪舊（drafts mailbox + account 沿定位結果）；(d) delete 失敗 → 不 throw，result `deleted_old: false` + 新舊並存明示。TDD：seam 測試覆蓋 4 條路徑（成功 / create-fail 不刪 / delete-fail 揭露 / refuse 兩態）
- [x] 2.4 result shape：`{deleted_old, old_draft_id, new_draft: <create_draft result string 原樣（含揭露後綴）>}`

## 3. 收尾

- [x] 3.1 全套件測試綠（940 tests 0 failures，census/disclosure guards 含）。ASSUMPTION（unattended）：live smoke deferred 至 attended verify — **必測三向量（verify R3 DA 點名）**：(1) GUI mailto 路徑的 create receipt（真草稿落地確認）；(2) 跨帳號 message id 語意（delete 述詞 id+subject 的實地行為）；(3) all-accounts scan 對「On My Mac」local drafts container 的 fail-closed 行為與訊息。unit/seam 已覆蓋 5 條路徑、順序契約、receipt gate 與述詞形狀
- [x] 3.2 CHANGELOG `[Unreleased]` entry（新 tool + list_drafts additive 欄位 + 揭露語意）；README tool 清單/計數同步（`ToolCountCensusGuardTests` 會 enforce）
