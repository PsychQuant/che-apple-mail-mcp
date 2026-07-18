# CRUD 裡面的 R 必須要直接存取資料庫

## 規則

任何「**讀**(R, Read)」操作 — 從 Apple Mail 抓郵件、附件、metadata、headers、search 結果、mailbox 列表等 — **必須**走 SQLite + `.emlx` 直讀路徑(`Sources/MailSQLite/`),AppleScript IPC 只能當 fallback,不可當預設。

「直接存取資料庫」= 開 `~/Library/Mail/V*/MailData/Envelope Index` (read-only SQLite) + 必要時 parse `~/Library/Mail/V*/.../*.emlx`。

## 為什麼

| 路徑 | 延遲(每筆) | 量級 |
|------|------|------|
| AppleScript IPC | ~1–2 秒 | 100s of ms 級 |
| SQLite + .emlx 直讀 | ~ms | 1000× 倍 |

讀取走 AppleScript 等於把 Mail.app 變成 read service — 每次 IPC 都要等 osascript spawn + Mail.app 排程 + AppleScript dispatch。對 batch read(歸檔、e-discovery、研究 corpus 撈)是設計級的 perf bug。

#12 (`save_attachment`) 證明過遷移可拿到 10–100× speedup。#69 補了 5 個 read tool 的 observability,讓 silent fallback 浮現。但**寫**(C/U/D — compose、mark_read、move、delete)走 AppleScript 是合理的:Mail.app 的狀態才是 source of truth,直接寫 SQLite 會造成 split-brain。

## R 涵蓋哪些 tools(必須走 SQLite + .emlx fast path)

- `list_accounts` / `get_account_info` (透過 `AccountMapper` plist 直讀)
- `list_mailboxes`
- `get_special_mailboxes` — **僅 mailbox 清單語意適用**；特殊匣的**實名解析**(unified 名 + #179 的 per-account 實名)是 Mail AppleScript model metadata,不在 Envelope Index,故走 AppleScript-primary(見「例外」段)
- `list_emails`
- `list_drafts` — **讀草稿匣訊息語意適用,但草稿匣**識別**是 app-level metadata**(同 `get_special_mailboxes`):純 SQLite 不可達,維持 AppleScript-primary(見「例外」段,#186)
- `get_email` / `get_emails_batch`
- `get_email_headers` / `get_email_source` / `get_email_metadata`
- `search_emails`
- `list_attachments` / `list_attachments_batch` / `save_attachment` (read 部分)
- `get_unread_count`
- `list_vip_senders`
- `list_signatures` / `list_smtp_servers` (plist 直讀)
- `list_rules` (plist 直讀,如可)

## C/U/D 路徑 — AppleScript IPC 為主(不適用本規則)

- compose / send / reply / forward / redirect
- mark_read / mark_as_junk / flag / set_flag_color / set_background_color
- move_email / copy_email / delete_email
- create/delete mailbox / rule
- check_for_new_mail / synchronize_account

## Hybrid pattern(實作慣例)

每個 read tool 必須:

1. **嘗試 SQLite 路徑** — `if let reader = indexReader, let rowId = Int(id) { ... }`
2. **Catch 任何錯誤,寫 stderr log** — 格式參照 `save_attachment` precedent (`Server.swift:1003-1009`):
   ```swift
   let message = "SQLite <tool> fast path failed for rowId=\(rowId): "
       + "\(error.localizedDescription); falling through to AppleScript\n"
   FileHandle.standardError.write(Data(message.utf8))
   ```
3. **Fall through 到 `mailController.<tool>(...)`** AppleScript 實作
4. **Init failure** (`Server.swift:25-37`) 也要 log stderr;`indexReader = nil` 不可 silent

#### 正反例

❌ Silent fallback(違反規則):
```swift
if let reader = indexReader, let rowId = Int(id),
   let mailboxUrl = try? reader.mailboxURL(forMessageId: rowId) {
    if let result = try? EmlxParser.read(...) { return result }
}
return try await mailController.fallback(...)  // 沒 log
```

✅ Logged fallback(符合規則):
```swift
if let reader = indexReader, let rowId = Int(id) {
    do {
        if let mailboxUrl = try reader.mailboxURL(forMessageId: rowId) {
            return try EmlxParser.read(rowId: rowId, mailboxURL: mailboxUrl)
        }
    } catch {
        let message = "SQLite ... fast path failed for rowId=\(rowId): "
            + "\(error.localizedDescription); falling through to AppleScript\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}
return try await mailController.fallback(...)
```

## 例外

- **EWS / Exchange accounts**:`.emlx` 不存在於 Exchange storage(server-side),AppleScript fallback 是**設計上正確**的路徑,不算違反規則。Init / per-call log 仍應產生,讓使用者能 distinguish 「EWS legitimate fallback」vs「Gmail silent failure」(見 #9, #69)。
- **`get_email_metadata`**:目前(2026-05)缺 AppleScript fallback,SQLite throw 會 propagate。已記錄為 #71,**待修不算豁免** — 修好之前不要新增同型違規。
- **`get_special_mailboxes`(特殊匣實名解析)**:特殊匣的**名稱**(unified `get name of drafts mailbox`,以及 #179 的 per-account 實名 via unified-children 反查)是 Mail AppleScript object model 的 metadata,**不存在於 Envelope Index**(SQLite 只有 message/mailbox row,沒有「drafts mailbox 的本地化顯示名」這種 app-level 語意)。因此 `get_special_mailboxes` 的名稱解析走 **AppleScript-primary 是設計上正確**,不算違反規則 — 這也修正了一個 pre-existing 描述/實作落差(unified 模式在 #179 之前就一直是 AppleScript)。對比之下,*mailbox 清單*(`list_mailboxes`)仍可由 Envelope Index 推導,維持 SQLite-first。#179 的 per-account 路徑無 SQLite 嘗試是預期的;EWS caveat 同上。
- **`list_drafts`(草稿匣**識別**)**:`list_drafts` 維持 **AppleScript-primary 是設計上正確**,不算違反規則 — 與 `get_special_mailboxes` 同根。讀草稿匣的**訊息**本身對 SQLite 友善(`EnvelopeIndexReader.listEmails` 已能用 `mb.url LIKE` 讀某匣訊息),但前一步「**哪個 mailbox 是草稿匣**」是 app-level metadata:Envelope Index `mailboxes` 表只有 `url / total_count / unread_count`,**無 special-mailbox role 欄位**,草稿匣的 `url` 帶 provider/locale 名(`[Gmail]/草稿` / `Drafts`),用名稱 heuristic 比對就是重蹈 #174 的 hardcoded-`Drafts` bug。識別草稿匣本質上要靠 AppleScript(#174 的 `ListDraftsScriptBuilder` unified-children 反查),所以**純 SQLite 的 `list_drafts` 不可達**;#174 已讓 `list_drafts` 在 Gmail/localized 帳號正確,草稿數通常少、AppleScript 延遲可接受。結論(#186,2026-06-14):這是 sanctioned exception 而非待補的 gap;若日後 batch 場景真有 evidence 需要 message-read 加速,走 hybrid(AppleScript 識別草稿匣 → SQLite 讀訊息),但 identification 那步仍是 AppleScript。

## 違反偵測

- PR review 必查:任何新增 read tool 是否走 hybrid pattern + 有 stderr log?
- Grep 反例:`grep -rn "try? reader\." Sources/CheAppleMailMCP/` 應該回 0 hit(全部都該是 do/catch 並 log)
- README "Performance & Storage" 表格必須跟現實同步;新加 read tool 要在表上一行

## 來源

- #12 — `save_attachment` AppleScript → SQLite + .emlx migration(canonical precedent)
- #7 — `search_emails` AppleScript-multiplexed 4× → SQLite
- #69 — read tool observability parity + 此規則的成形討論
- #71 — `get_email_metadata` AppleScript fallback gap(待修)
- #9 — EWS / Exchange caveat
- #186 — `list_drafts` 草稿匣識別是 app-level metadata → sanctioned AppleScript-primary exception(won't-implement,2026-06-14)

## `whose content contains` 全文掃描禁令 (#221)

任何 read 路徑（shipped code、live test、ad-hoc 驗證）**絕不可**用 `messages ... whose content contains "<x>"`。這是 O(corpus) predicate：Mail 必須把**每封信的 body 反序列化**才能比對，在大信箱（~80k）會 OOM 直接拖垮 Mail.app（#218 spike 實證）。

安全替代：
- **subject / sender 比對**（`whose subject contains ... or sender contains ...`）—— shipped `searchEmails`（`MailController.swift:520/550/574`）就是這樣，不碰 content。
- **scope 到特定小信箱**（如某帳號的 Drafts，~10s 封）再逐封讀 `content of m` —— 有界，可接受。
- **id-delta 清理**：要刪測試草稿用「snapshot ids before → 刪 not-in-before」，不要靠 content 比對找。
- live-test 找已存草稿的 .emlx：用 disk `grep`（檔案系統，不載入 Mail body）或 subject-match，不要 `whose content contains`。

**Regression guard**：`Tests/CheAppleMailMCPTests/NoContentContainsScanGuardTests.swift` 掃 `Sources/CheAppleMailMCP/`，任何 `whose content contains` 出現即 fail。注意這條鎖的是**「shipped read 路徑」**；`MailAppIntegrationTests.swift` 的 `content of m` 迴圈 scope 在 Drafts 小匣、有界，不在此禁令範圍（但若日後 batch 場景變大，同樣改走 subject/id 路徑）。
