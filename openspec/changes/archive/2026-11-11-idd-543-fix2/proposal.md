## Why

#543 第 2 輪 verify（https://github.com/PsychQuant/che-apple-mail-mcp/issues/543#issuecomment-6794688209）的 Blocking：驗證器判斷的是 kernel 會開的那個路徑，但 Mail 從來沒有收到那個路徑：GUI 步驟把呼叫端原本的字串貼進開檔面板的 Go-to-folder 欄位，而沒有人觀察過那個欄位怎麼讀 symlink 之後的 `..`。若它照字面收合 `..`，第 1 輪修正會讓一個舊版拒絕的路徑被接受；若它照實體路徑解析，舊版才是錯的。兩種讀法總有一種在某個 `..` 路徑上錯。

## What Changes

- 附件路徑只要有 `.` 或 `..` 段，就在任何其他檢查之前拒絕，訊息為 `'<path>' rejected: contains a '.' or '..' path component`。沒有這種段時，字面與實體兩種讀法指向同一個檔，判斷結果與 Go-to-folder 欄位的行為無關，也保留呼叫端給的檔名。
- spec、doc comment、SECURITY.md 改為照實描述：存在檢查用呼叫端原本的路徑（kernel 的查找，較安全的一側），deny-list、allow-list、種類檢查用解析後的路徑。
- SECURITY.md：TOCTOU 時間窗改為約 90 秒（GUI 期限），章節開頭加上 `update_draft`，Known limitations 補上 deny-list 以字串前綴比對（hard link、#671）與 `/dev/fd/N`（#669）。CHANGELOG 修正過度宣稱。

## Non-Goals

- 不把解析後的路徑交給 Mail：非 ASCII 的檢查是在原始路徑上做的（指向非 ASCII 目標的 link 會繞過它），收件人看到的檔名也會變成目標的檔名。列在 #669。
- `~user/`、控制字元（#669）、根層路徑前綴（#671）、附件數上限與 GUI 期限（#672）都是既有問題，另開 follow-up。

ASSUMPTION: 選擇拒絕所有 `.`／`..` 段，而不是只拒絕兩種讀法不同的路徑：規則封閉、與欄位實際使用的讀法無關；代價是過去接受的良性 `..` 路徑也會被拒（呼叫端改傳不含 `..` 的路徑即可）。較窄的做法列在 cluster PR 的 "Decisions to look at"。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `message-composition`：MODIFIED Requirement: Attachment paths must be regular files。

## Impact

- Affected specs: `message-composition`
- Affected code: `Sources/CheAppleMailMCP/AppleScript/MailController.swift`（`validateAttachmentPaths`）
- Tests: `Tests/CheAppleMailMCPTests/MailControllerComposeTests.swift`
- Docs: `SECURITY.md`、`CHANGELOG.md`
