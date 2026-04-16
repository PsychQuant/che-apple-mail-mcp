## Why

四個寫信工具（`compose_email`, `create_draft`, `reply_email`, `forward_email`）都透過 AppleScript 的 `content` property 傳遞 body，這個 property 只接受 plain text。使用者傳入 HTML 標籤（例如 `<b>`、`<a href="...">`）時，收件人看到的是字面的標籤字元，不是渲染後的格式。讀取端（`get_email` 等）已有 `format: "html" | "text" | "source"` 參數；寫入端缺少對稱支援，造成以下實務影響：

- APA / MLA 引用無法在一次呼叫中完成（journal 名要 italic，book title 要 italic）
- 含連結的郵件必須收件後手動修復
- Reply / forward 會把原信的 rich text 降格為 plain text，破壞 signature 與原格式

這個缺口被追蹤在 [#15](https://github.com/PsychQuant/che-apple-mail-mcp/issues/15)（bug, P0）與 [#14](https://github.com/PsychQuant/che-apple-mail-mcp/issues/14)（enhancement），#15 涵蓋範圍更廣，superset #14。

## What Changes

- 四個寫信工具（`compose_email`, `create_draft`, `reply_email`, `forward_email`）新增選用參數 `format: "plain" | "markdown" | "html"`
- 預設值 `"plain"`，既有 caller 完全向後相容
- `"markdown"` 模式：透過 Swift 原生 `AttributedString(markdown:)` 解析 body，再轉為 HTML 寫入 AppleScript `html content` property
- `"html"` 模式：body 直接當作 HTML 寫入 AppleScript `html content` property
- Reply / forward 在非 plain 模式下：使用者 body 作為 HTML fragment，原信內容包在 `<blockquote>` 內保留
- 新增 capability `message-composition`，把四個既有 tool 與新 format 行為一併 codify（此 capability 過去沒有 spec 記錄）

## Non-Goals

- **不支援 MIME multipart 同時夾帶 plain + HTML fallback**：Mail.app AppleScript `html content` 行為即足夠，引入 MailKit / 低階 MIME 組裝超出本 change 範圍
- **不支援嵌入圖片 / CID attachment**：附件目前由 `attachments` 參數處理，inline image 屬於未來工作
- **不支援 full CommonMark / GitHub-flavored markdown**：支援 `AttributedString(markdown:)` 的 subset（粗體、斜體、連結、code、基本 list），table / footnote / 自訂 extension 明確不支援
- **不改變讀取端 `get_email` format 語意**：本 change 只處理寫入端對稱

## Capabilities

### New Capabilities

- `message-composition`: Mail.app 寫信工具集的 MCP 介面。涵蓋四個 composing tools（compose_email, create_draft, reply_email, forward_email）的 input schema、AppleScript 執行、format 參數（plain / markdown / html）、reply-forward 的原信合併語義

### Modified Capabilities

(none — 寫入端過去沒有 spec，本 change 首次建立)

## Impact

- **Affected specs**: 新增 `openspec/specs/message-composition/spec.md`
- **Affected code**:
  - `Sources/CheAppleMailMCP/Server.swift`（四個 composing tool 的 inputSchema 新增 `format` 屬性；handler dispatch 讀取 `format`）
  - `Sources/CheAppleMailMCP/AppleScript/MailController.swift`（`composeEmail`, `createDraft`, `replyEmail`, `forwardEmail` 四個方法簽章新增 `format` 參數；新增 markdown/html → AppleScript `html content` 路徑；reply/forward 的 HTML blockquote 合併邏輯）
  - 新增（可能）`Sources/CheAppleMailMCP/MarkdownRendering.swift` 或類似的輔助模組，封裝 `AttributedString(markdown:) → HTML string` 的轉換
- **Affected dependencies**: 零新增 Swift Package dependency（`AttributedString(markdown:)` 是 Foundation 內建）
- **Affected closed issues**: 本 change 實作後 PR 引用 `Closes #14, Closes #15`
- **Platform**: macOS 13+（Package.swift 已聲明）；`AttributedString(markdown:)` 需要 macOS 12+，滿足；AppleScript `html content` 已在 macOS 26 / Mail 16 實證可寫
