## Context

`MailController.getSpecialMailboxes()` 目前無參數，回六個 **app-level unified** 特殊匣名（`get name of inbox` / `get name of drafts mailbox` / `… sent / trash / junk / outbox`）；`get_special_mailboxes` 工具 schema 的 `properties` 為空。多帳號環境下這無法區分各帳號的本地化／provider 特殊匣名。

#174 已在 `ListDraftsScriptBuilder` 證實 **unified-children 反查 pattern**：`every mailbox of drafts mailbox` 回每帳號一個 child mailbox，逐一用 `id of account of mb`（或 `name of account of mb`）反查所屬帳號；無法解析 `account` 的 child（On-My-Mac／local container）以 per-child `try` guard 跳過。本設計把該 pattern 從 drafts 泛化到 sent/trash/junk（同 `<X> mailbox` 結構；`inbox` deferred 見 D4），並把結果暴露給 `get_special_mailboxes` 呼叫端。

約束：names 是 Mail AppleScript model 的 metadata（不在 Envelope Index），故維持 AppleScript-primary（非 r-must-direct-db SQLite-path 候選）。account 解析必須走既有 chokepoint（`resolveAccountRef` + `AccountMapper.uuids(forEmail:)`），避免重蹈 #176 的 `-1728` display_name namespace bug。

## Goals / Non-Goals

**Goals:**

- `get_special_mailboxes` 接受 optional `account_id` / `account_name`，回該帳號的特殊匣實名。
- 省略帳號時輸出與現狀 **byte-unchanged**（backward-compat）。
- per-account 解析對 unresolvable／缺型別的 child **graceful**（跳過／省略，非 fatal）。
- builder 為 pure free function，可不啟動 actor 直接單元測試（同 `ListDraftsScriptBuilder`）。

**Non-Goals:**

- `outbox` 的 per-account 解析（transient send queue）。
- 特殊匣名的 SQLite 直讀。
- 一次回全部帳號（單帳號單物件）。
- `list_drafts` 的 SQLite fast path（#186，序在本變更後）。

## Decisions

- **D1 — optional account 參數，省略 → unchanged unified。** `account_id` / `account_name` 皆 optional。兩者皆無 → 跑現有六個 unified script，回現狀形狀。理由：保護既有 caller；per-account 是純加法。
- **D2 — 提供帳號 → 單一物件。** 回 `{account_id, account_name, drafts?, sent?, trash?, junk?}`（單一帳號；`inbox` deferred per D4，`outbox` excluded）。理由：輸入是單一帳號，呼叫端要把名字餵進 `mailbox` 參數，單物件最直接；all-accounts 清單是 non-goal。`account_id`/`account_name` 為 matched account 的 canonical 值(非 echo 輸入)。
- **D3 — graceful skip / omit，never fatal。** unified child 無 `account` property → per-child `try` 跳過（同 #181 finding 3）。帳號缺某特殊匣型別 → 省略該 key。理由：一個 local container 或缺 junk 匣不該炸掉整個查詢。
- **D4 (revised, #179 verify R2) — ship drafts/sent/trash/junk; defer `inbox` + exclude `outbox`.** Only the four `<X> mailbox` special mailboxes are shipped per-account: they are the **same structural kind** as the `drafts mailbox` #174 empirically proved exposes per-account children, so the reverse-lookup generalizes by analogy. `outbox` is excluded (app-level transient send queue). **`inbox` is deferred**: it is referenced as `inbox` (not `<X> mailbox`) and its per-account child semantics are structurally different + unverified — shipping it now would assert unverified behavior (verify R2 devils-advocate). It is added once task 4.2's live multi-account check confirms `every mailbox of inbox` yields per-account children. The original "omit inbox if no child" graceful-skip guarded only against errors/absent children, not against `inbox` having *different* per-account semantics (e.g. returning the unified inbox) — hence the cleaner conservative choice is to not enumerate `inbox` at all yet.
- **D5 — 新 `SpecialMailboxesScriptBuilder` + 重用 resolver。** 複製 `ListDraftsScriptBuilder` 的 loop 泛化到各型別；account_id/account_name → UUID 經 `resolveAccountRef` + `AccountMapper.uuids(forEmail:)`。AppleScript-primary。理由：proven pattern；單一 resolver chokepoint。

## Implementation Contract

**Behavior:**
- `get_special_mailboxes`（無 account）→ 與現狀完全相同：`{inbox, drafts, sent, trash, junk, outbox}` 的 unified 名稱字串。
- `get_special_mailboxes`（給 `account_id` 或 `account_name`）→ 該帳號的單一物件：`{account_id, account_name, drafts?, sent?, trash?, junk?}`，值為該帳號特殊匣實名；缺的型別省略該 key（`inbox` deferred per D4，`outbox` excluded）。

**Interface / data shape:**
- Tool schema：新增 `account_id`（string, optional）+ `account_name`（string, optional）到 `get_special_mailboxes` 的 `properties`（皆非 required）。
- `MailController.getSpecialMailboxes(accountId: String? = nil, accountName: String? = nil) throws -> [String: Any]`（預設參數保留現有無參呼叫者 source-compat）。
- `SpecialMailboxesScriptBuilder.swift`：free function（如 `buildSpecialMailboxNamesScript(accountRef:specialKinds:) -> String` 或每型別一段）建 per-account unified-children loop，per-child `try` guard，回各型別實名；account selector 由 `resolveAccountRef(accountId:accountName:)` 提供。
- account 解析：email-form `account_name` → `AccountMapper.uuids(forEmail:)` → UUID（同 #176 handler-layer normalization）。

**Failure modes:**
- 給了 account selector 但**完全比不到任何帳號** → `MailError.operationFailed`，actionable（指向 `list_accounts` / 說明 description-vs-email namespace），同 `list_drafts` no-match 精神。
- 帳號比到、但某特殊匣型別無對應 child → **省略**該 key（非 error）。
- unresolvable per-child（無 `account`）→ **跳過**（`try` guard）。
- 省略 account → 不觸發任何 per-account 邏輯（行為與今日相同）。

**Acceptance criteria:**
- `SpecialMailboxesScriptBuilderTests`：per-account loop 對每型別 emit 正確 selector（`id of account of mb` UUID 模式 / `name of account of mb` fallback）、per-child `try` guard 存在、escape discipline、無 hardcoded 特殊匣英文名。
- Schema 測試：`get_special_mailboxes` advertise `account_id` + `account_name`，皆非 required。
- Handler wiring：decode account_id → resolve → dispatch 到 per-account 分支；省略 → unified 分支（byte-unchanged，golden/結構 pin）。
- `swift test --skip MailAppIntegrationTests` 全綠。
- **Live check（apply 期，FDA + 多帳號）**：對一個 Gmail + 一個 iCloud 帳號跑 per-account 模式，確認回該帳號本地化實名（Gmail `草稿`/`垃圾郵件`、iCloud `Drafts`/`Junk`）；定案 D4 的 `inbox` per-account 行為。
