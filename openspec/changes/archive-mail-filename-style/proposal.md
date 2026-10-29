## Why

archive-mail 目前在 client 重算檔名，preview 的 UTC 時間卻無法還原信件 Date header 的原始日期。#340 將命名移至已持有原始資料的伺服器，讓檔名日期與 frontmatter 同源。

## What Changes

- 新增 opt-in `opts.filename_style: "archive-mail"`，保留回覆前綴、Unicode 與連續 dash，截至 50 graphemes。
- 預設樣式、自訂 template 與逐 id override 維持現有行為與優先權。
- 新樣式沿用伺服器磁碟碰撞處理；SOP 改用新選項並以 manifest 路徑為準。

## Capabilities

### New Capabilities

- `archive-mail-filenames`: 批次匯出樣式、日期同源、優先權及 SOP 能力檢查。

### Modified Capabilities

無。

## Impact

`ExportEmailsMarkdown.swift`、`EmailMarkdownRenderer.swift`、`Server.swift`、對應測試與 `plugin/commands/archive-mail.md`。不新增依賴、不修改使用者真實信件或舊歸檔。
