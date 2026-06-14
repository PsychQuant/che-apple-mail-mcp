## 1. Builder（pure free function，TDD）

- [x] 1.1 撰寫 `SpecialMailboxesScriptBuilderTests`（RED）：per-type unified-children loop 對每個特殊匣型別 emit 正確 selector（UUID 模式 `id of account of mb` / fallback `name of account of mb`）、含 per-child `try` guard、escape discipline、無 hardcoded 英文特殊匣名 —— 引用尚未存在的 builder，編譯失敗確認 RED
- [x] 1.2 新增 `Sources/CheAppleMailMCP/AppleScript/SpecialMailboxesScriptBuilder.swift`：free function 由 `resolveAccountRef(accountId:accountName:)` 取得 account ref，對 drafts/sent/trash/junk 各建 unified-children 反查 script（`inbox` **未** ship，deferred 至 4.2）—— 1.1 全部 GREEN

## 2. MailController per-account 分支（交付 spec 需求 "Per-account special-mailbox name resolution"）

- [x] 2.1 實作 spec 需求 "Per-account special-mailbox name resolution"：`getSpecialMailboxes(accountId: String? = nil, accountName: String? = nil)` 加 optional 參數 + per-account 分支：有 selector → 呼叫 builder 組成單一物件 `{account_id, account_name, drafts?, sent?, trash?, junk?}`（缺型別省略 key；`inbox` deferred 未 ship）；無 selector → 現有 unified 六鍵輸出不變 —— 既有無參呼叫者 source-compat、編譯通過
- [x] 2.2 account 解析重用 `AccountMapper.uuids(forEmail:)`（email-form `account_name` → UUID，同 #176 handler-layer normalization）；selector 完全比不到帳號 → `MailError.operationFailed` actionable（指向 `list_accounts`）—— 單元測試覆蓋 email→UUID 解析 + no-match 錯誤訊息

## 3. Server schema + handler

- [x] 3.1 [P] `get_special_mailboxes` schema 的 `properties` 加 `account_id` + `account_name`（皆 optional、非 required）—— schema 測試 assert 兩者被 advertise 且不在 `required`
- [x] 3.2 handler `decodeAccountId` + `account_name` → dispatch per-account 分支 vs unified 分支 —— 結構 wiring pin：handler 解析並傳入 `getSpecialMailboxes`；省略 selector 時輸出 byte-unchanged

## 4. Verify + docs

- [x] 4.1 `swift build` clean + `swift test --skip MailAppIntegrationTests` 全綠（0 `CheAppleMailMCPTests` failures）
- [ ] 4.2 Live check + inbox follow-up（FDA + Gmail/iCloud 多帳號，DEFERRED — classifier-blocked on live Mail）：(a) 確認 drafts/sent/trash/junk per-account 回本地化實名（Gmail `草稿`/`垃圾郵件`、iCloud `Drafts`/`Junk`）；(b) 實測 `every mailbox of inbox` 是否有 per-account child —— 若有，把 `inbox` 加回 `perAccountSpecialMailboxes` + spec + 測試（目前 inbox 已**保守 deferred**，未 ship）；手動實測紀錄貼到 #179  <!-- BLOCKED: needs live Mail.app (FDA + Gmail/iCloud); deferred per #179 apply -->
- [x] 4.3 [P] `CHANGELOG.md` `[Unreleased]` Added 條目（`get_special_mailboxes` per-account；backward-compat 省略路徑不變；Refs #179）
