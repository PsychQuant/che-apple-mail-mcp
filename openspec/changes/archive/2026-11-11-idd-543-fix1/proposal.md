## Why

#543 第 1 輪 verify（https://github.com/PsychQuant/che-apple-mail-mcp/issues/543#issuecomment-6793545465）的兩個 Blocking：

1. 解析用 `URL.standardized`，它在 `resolvingSymlinksInPath()` 之前就從字串刪掉 `..`。所以 `L/../x`（L 是指向別處目錄的 symlink）每一層看的都是 `dir/x`，kernel 開的卻是 L 目標旁邊的 `x`。結果是合法的 `L/../target.txt` 被拒為 `unreadable type`（本次引入），有 decoy 時 `L/../pipe` 被接受（新的一層可被繞過），deny-list 與 allow-list 也判斷錯的路徑（#38 既有）。
2. `update_draft` 只在 `createDraft` 裡驗證附件，那時已經跑過兩次唯讀的草稿掃描，所以「在任何 Mail 操作之前」對它不成立；spec、CHANGELOG、SECURITY.md 也沒有寫到它。

## What Changes

- 附件路徑先依工作目錄轉成絕對路徑，再只用 `resolvingSymlinksInPath()` 解析（不先 `.standardized`），讓 `..` 從前一個 link 的目標算起，與 kernel 一致；存在檢查、deny-list、allow-list、種類檢查都用這一個解析後的路徑。這同時修正 #38 deny-list／allow-list 的 `..` 繞過。
- `update_draft` 在定位草稿的掃描之前驗證附件（與 #411 的收件人檢查同一處）。
- 種類讀不到時的標籤改為 `type could not be read`。
- SECURITY.md §2 改寫解析方式、§5 與 TOCTOU 說明更正、歷史列依日期排序；CHANGELOG 寫明 `update_draft` 與 `..` 解析的改變。

## Non-Goals

- 不強制絕對路徑（schema 寫 absolute，但目前接受相對路徑並以 server 的工作目錄解析）、不處理 `/dev/fd/N` 別名、不處理 `import_mailbox` 沒有路徑檢查：三者都要先定政策，另開 follow-up。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `message-composition`：MODIFIED Requirement: Attachment paths must be regular files。

## Impact

- Affected specs: `message-composition`
- Affected code: `Sources/CheAppleMailMCP/AppleScript/MailController.swift`（`validateAttachmentPaths`、`nonRegularFileKind`、`updateDraft`）
- Tests: `Tests/CheAppleMailMCPTests/MailControllerComposeTests.swift`
- Docs: `SECURITY.md`、`CHANGELOG.md`
