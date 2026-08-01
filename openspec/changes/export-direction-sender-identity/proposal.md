# export-direction-sender-identity

## Why

`batch_export_emails_markdown` 的 frozen frontmatter `direction` 欄位目前由**整批單一值**決定：`mailbox` 參數字串的 substring heuristic（`Server.swift:1936` — 含 "sent"/"寄件" → `sent`，否則 `received`）。Gmail 帳號的寄出信實際存放於 `[Gmail]/全部郵件`（All Mail 是雙向超集，mailbox 根本不攜帶 direction 資訊），導致從 All Mail 匯出時**所有自己寄出的信都被持久化標成 `direction: received`**（#316 實測 5 封 thread、3 封自寄全錯）。這是 frozen frontmatter 的資料正確性缺陷，且每個 caller（含 archive-mail SOP）都得自行做 sender 分批才能繞過 — footgun 對所有 caller 上膛。

## What Changes

- **Server-side per-email direction 推導（選項 a，已由使用者核准）**：對每封匯出的信，取 bare sender（`ExportEmailsMarkdown.swift:433` 既有的 `EmailMarkdownRenderer.bareEmail(content.sender)`）與該帳號的 own addresses 集合（來自 index account mapping / `EnvelopeIndexReader` 的 `email_addresses`，**無 AppleScript 呼叫**）做 case-insensitive 比對：sender ∈ own addresses → `sent`，否則 `received`。
- **Fail-open**：own addresses 集合為空（EWS/Exchange 帳號 — #9/#11 家族 — 或 index 不可用）時，回退到現行 mailbox-label 整批行為，**不**讓匯出失敗。
- **揭露（negative-only，比照 `body_downloaded: false` 精神）**：走 fail-open 回退路徑的每個 manifest item 附 `direction_inferred: true`，表示該封的 direction 是 mailbox-label 推測而非 sender-identity 判定；sender-identity 判定成功的 item **不**帶此欄位。
- **`mailbox` 參數降級為 fallback 標籤來源**：`Server.swift:785` 的參數描述改寫 — 不再宣稱「used only to label direction」暗示任何 mailbox 字串都合理，明確說明 direction 主要由 sender identity 推導、mailbox 僅在無法判定時作 fallback 依據。
- **Frozen frontmatter 六欄位契約不變**：不加欄位、不改順序，只讓 `direction` 的**值**變正確。

## Non-Goals

（design.md 將建立，rejected approaches 詳見該檔 Goals/Non-Goals 段。）

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `batch-operations`: `batch_export_emails_markdown` 的 `direction` 推導從「整批 mailbox-label heuristic」改為「per-email sender-identity 判定 + fail-open 回退 + manifest `direction_inferred` 揭露」；frozen frontmatter 六欄位契約本身不變。

## Impact

- Affected specs: `batch-operations`（direction 推導 requirement 新增 + manifest 欄位揭露）
- Affected code:
  - `Sources/CheAppleMailMCP/ExportEmailsMarkdown.swift` — run loop 內 per-email direction 判定、manifest item `direction_inferred` 欄位
  - `Sources/CheAppleMailMCP/Server.swift` — handler 端組 own-addresses 集合（`Server.swift:1936` 附近）、`Server.swift:785` 參數描述改寫
  - `Sources/MailSQLite/EnvelopeIndexReader.swift` —（如需）own-addresses 查詢的既有讀取路徑重用，預期不改 schema
  - `Tests/CheAppleMailMCPTests/ExportEmailsMarkdownTests.swift` — direction 判定 + fail-open + 揭露欄位測試
- 下游（本 change 之外的後續工作，不在本 repo）：plugin repo `archive-mail.md` Step 5.0 移除兩批分割紀律（隨 PR #120 系列處理）
