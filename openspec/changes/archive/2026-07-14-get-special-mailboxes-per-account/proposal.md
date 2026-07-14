## Why

`get_special_mailboxes`（`MailController.getSpecialMailboxes`）目前只回 **app-level unified** 特殊匣名（`get name of drafts mailbox` 等），多帳號環境下無法回答「**某個帳號**的草稿匣／寄件匣／垃圾桶叫什麼」—— Gmail 帳號的 `草稿` / `垃圾郵件` 與 iCloud 的 `Drafts` / `Junk` 在 unified 名稱下無從區分。

#174 實測（2026-06-11）證實：per-account 特殊匣屬性（`drafts mailbox of account X`）在 Mail AppleScript model **不存在**（-1728），但 unified 特殊匣的 per-account 子 mailbox 可用 `id of account of mb` 反查帳號 UUID（unified-children 反查 pattern，目前只在 `list_drafts` 用到）。本變更把該能力泛化到 sent/trash/junk（與 drafts 同為 `<X> mailbox` 結構；`inbox` deferred，見 What Changes / design D4）並暴露給呼叫端，讓呼叫端能把特殊匣實名餵進 `mailbox` 參數（搭配 #174 的巢狀解析）。Refs #179。

## What Changes

- `get_special_mailboxes` 新增 optional `account_id` / `account_name` 兩個參數。
- **省略帳號** → 輸出與現狀 byte-unchanged（六個 unified 名稱 `{inbox, drafts, sent, trash, junk, outbox}`），維持 backward-compat。
- **提供帳號** → 回該帳號的**單一物件** `{account_id, account_name, drafts, sent, trash, junk}`，值為該帳號的特殊匣**實名**（本地化／provider 名）。`inbox` per-account 解析 **deferred**（結構不同、未實測，見 design D4）；`outbox` 維持 unified-only。
- 無法解析 `account` 的 unified child（On-My-Mac／local container）**跳過**；該帳號缺某特殊匣型別 → **省略**該 key，不讓整個呼叫 fail。
- `outbox` 在 per-account 模式維持 unified-only（transient send queue，不暴露 per-account child）。
- 新增 `SpecialMailboxesScriptBuilder`（複製 #174 `ListDraftsScriptBuilder` 的 unified-children loop + per-child `try` guard，泛化到各特殊匣型別）。
- `account_id` / `account_name` → UUID 解析重用既有 `resolveAccountRef` + `AccountMapper.uuids(forEmail:)`（與 #176 一致，避免 -1728 namespace bug）。

## Non-Goals (optional)

- **`outbox` 的 per-account 解析** —— transient send queue，預期無 per-account child；維持 unified。
- **特殊匣名的 SQLite 直讀** —— 特殊匣**實名**是 Mail AppleScript model 的 metadata（unified-children），不來自 Envelope Index；本能力維持 AppleScript-primary。（`list_drafts` 的 SQLite fast path 是 #186 的獨立議題，序在本變更之後。）
- **一次回全部帳號的特殊匣** —— 輸入是單一帳號，回單一物件即可；all-accounts 清單若日後需要再另開。
- **改變省略帳號時的輸出形狀** —— 嚴格維持現有 unified 六鍵輸出。

## Capabilities

### New Capabilities

- `special-mailbox-resolution`: per-account special-mailbox real-name resolution — given an account selector, return that account's localized/provider special-mailbox names via the unified-children reverse-lookup; account-agnostic unified output when no selector is given.

### Modified Capabilities

(none)

## Impact

- Affected specs: `special-mailbox-resolution`（new）
- Affected code:
  - `Sources/CheAppleMailMCP/Server.swift` — `get_special_mailboxes` 的 schema（加 `account_id` / `account_name`）+ handler（decode + resolve + dispatch）
  - `Sources/CheAppleMailMCP/AppleScript/MailController.swift` — `getSpecialMailboxes` 加 optional account 參數 + per-account 分支
  - `Sources/CheAppleMailMCP/AppleScript/SpecialMailboxesScriptBuilder.swift`（new）— per-account unified-children builder
  - 重用 `AppleScriptRefBuilder.resolveAccountRef`、`MailSQLite/AccountMapper.uuids(forEmail:)`
  - `Tests/CheAppleMailMCPTests/SpecialMailboxesScriptBuilderTests.swift`（new）
- Refs #179；序列：本變更 land 後，#186（list_drafts SQLite fast path）重用此處的 drafts-mailbox 解析 + 共同編輯 `.claude/rules/r-must-direct-db.md`。
