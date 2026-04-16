## Context

Mail.app MCP server 當前提供四個 composing tools，都透過 AppleScript 的 `content` property 傳遞 body 字串。`content` property 在 Mail.app 內部型別為 plain `text`，任何 HTML 標籤會原封不動變成字面字元。讀取端 `get_email` / `get_email_source` 已經有 `format: "html" | "text" | "source"` 參數（見 `Server.swift:124, 623`；`MailController.swift:317`），寫入端缺少對稱支援構成 #15（P0 bug）與 #14（feature request）的根因。

技術前提已於 `/spectra-discuss` 階段做實證驗證：在 macOS 26.4.1 / Mail 16.0 上，AppleScript 的 `html content` property **可寫**（透過 `osascript` 直接測試確認）。這消除了此前關於 Mail.app 17+ 支援度的不確定，使得 `html content` 成為首選實作路徑，不需要 clipboard paste / MailKit / 低階 MIME 組裝。

Stakeholders：

- Issue #15 / #14 報告者（使用者）
- 所有透過此 MCP 產生 APA / MLA 引用格式的郵件之學術使用者
- Mail.app signature 使用者（reply / forward 應保留 signature 樣式）

## Goals / Non-Goals

**Goals:**

- 四個 composing tools（`compose_email`, `create_draft`, `reply_email`, `forward_email`）取得對稱的 `format` 參數支援
- Default 為 `"plain"` 以保證既有 caller 完全向後相容
- `"markdown"` 模式提供 zero new dependency 的路徑（Swift 原生 `AttributedString(markdown:)`）
- `"html"` 模式讓呼叫者可直接提供 pre-rendered HTML（例如從其他系統 render 好的 newsletter）
- Reply / forward 在非 plain 模式下正確合併使用者 body 與原信內容

**Non-Goals:**

- **MIME multipart 同時支援 plain 與 HTML**：Mail.app 的 `html content` 產出的郵件在收件端即已是富文字；不自行組 multipart
- **Inline image / CID 附件**：`attachments` 參數只處理檔案附件，不處理 HTML 內嵌圖片
- **Full CommonMark / GFM**：以 `AttributedString(markdown:)` 支援的 subset 為界（粗體、斜體、連結、list、code），table / footnote / 自訂 extension 超出範圍
- **改變讀取端行為**：讀取端 `format` 語意不動
- **新 dependency**：不引入 swift-markdown / cmark-gfm 等外部 package

## Decisions

### AppleScript html content property as the rendering target

採 AppleScript 的 `html content` property 作為 HTML 寫入 Mail.app 的方式，而非 clipboard paste 或 MailKit。

**Rationale**：

- 實證在 macOS 26 / Mail 16 可寫（`/spectra-discuss` 的 spike 已驗證）
- 與既有純 AppleScript 架構一致，不引入新抽象層
- Clipboard paste 會污染使用者的剪貼簿，需要 save / restore 機制，複雜且易出錯
- MailKit 引入 Entitlement 與 notarization 成本，且綁定 Mail extension 架構，超出 MCP server 情境

**Alternatives considered**：

| 方案 | 拒絕原因 |
|------|----------|
| Clipboard paste rich text | 污染使用者剪貼簿；save/restore 邏輯在 concurrent MCP 呼叫下不安全 |
| MailKit API | 需要 Entitlement、code signing 調整；API 設計綁定 Mail extension |
| 自行產生 `.eml` 再 import | 無法直接 send，使用者需手動點送出 |

### Markdown parsing via Swift-native AttributedString(markdown:)

Markdown → HTML 的轉換走 Swift 內建 `AttributedString(markdown:)`，再透過 `NSAttributedString.data(..., documentType: .html)` 轉為 HTML 字串。

**Rationale**：

- Zero new Swift Package dependency（Package.swift 保持簡潔）
- macOS 12+ 支援，專案平台下限（macOS 13）滿足
- 涵蓋 #15 / #14 所要求的 subset：粗體、斜體、連結、list、inline code
- Swift 原生實作表示日後若 Apple 擴充 subset，專案自動受惠

**Alternatives considered**：

| 方案 | 拒絕原因 |
|------|----------|
| swift-markdown (Apple) | 雖然支援 GFM，但引入 SwiftPM dependency；目前 subset 已足夠 |
| cmark-gfm | C library，需要 wrapping 與 memory management；過度工程 |
| 自行寫 markdown regex parser | Edge case 地獄（巢狀、escape、link 內含 markdown）|

### Default format is "plain" for backwards compatibility

`format` 參數的預設值為 `"plain"`，而非 `"markdown"`。

**Rationale**：

- 向後相容是 P0 bug fix 能快速上線的先決條件
- 既有 caller 傳 `body: "Hi\n\n*Regards*"` 不應被無預警解析成 italic
- 使用 `AttributedString(markdown:)` 時，`_` 和 `*` 是語意字元，若無預警啟用 markdown 會改變既有行為

**Trade-off**：新 caller 必須記得顯式寫 `format: "markdown"`，可能造成新功能初期 adoption 較慢。接受這個 trade-off，以 tool description 中明確標示「default is plain; set format to 'markdown' for rich text」作補償。

**Alternatives considered**：Default `"markdown"`，文件要求使用者 escape `*` `_`。拒絕理由：既有程式所有 body 字串都可能意外受影響，違反 semver 精神（MCP tool 輸入 schema 變更應向後相容）。

### Reply/forward merges original content via HTML blockquote

當 `format` 是 `"markdown"` 或 `"html"` 時，`reply_email` 與 `forward_email` 的合併語義為：

```
<user-body-as-html>

<hr>
<blockquote>
  <original-content-as-html>
</blockquote>
```

原信內容（透過 `content of originalMsg` 或 `html content of originalMsg` 取得）放入 `<blockquote>` 內。當 `format` 是 `"plain"` 時維持既有字串拼接行為（`body & return & return & content`）。

**Rationale**：

- Blockquote 是 email quoting 的 web 標準慣例，收件端 Mail.app 預設就有樣式
- 明確分離使用者內容與 quoted 內容，避免 malformed HTML
- 保留 plain 模式的既有行為，繼續向後相容

### Format parameter symmetry with getEmail read path

寫入端的 `format` 參數與讀取端 `get_email(format:)` 對稱，使用單一參數而非新增 `html_body` 並行參數。

**Rationale**：

- Codebase 已存在「content 需要 format awareness」概念（`Server.swift:124, 623, 758, 1194`；`MailSQLite/EmailContent.swift:23`）
- API 表面對稱減少使用者認知負擔
- 未來若要加更多 format（例如 `"rtf"`），擴展點清楚

**Alternatives considered**：兩個並行 `body` / `html_body` 參數。拒絕理由：使用者需知道兩者互斥規則；schema 複雜度增加。

### Markdown rendering is encapsulated in a helper module

新增 `Sources/CheAppleMailMCP/MarkdownRendering.swift`（或類似命名），封裝：

```swift
enum BodyFormat: String { case plain, markdown, html }

struct ComposedBody {
    let htmlContent: String?  // nil when format == .plain
    let plainContent: String  // always set — used as fallback for `content` property
}

func renderBody(_ body: String, format: BodyFormat) -> ComposedBody
```

**Rationale**：

- `MailController.swift` 已逼近 800 行，`AttributedString` → HTML 的細節不該再塞進去
- 獨立模組便於單元測試（不需要跑 AppleScript 即可驗證 markdown 渲染結果）
- 四個 composing 方法共用同一個 renderer，避免邏輯重複

## Risks / Trade-offs

- **[CONFIRMED Limitation] `html content` 讀取被 Mail.app AppleScript 封鎖（macOS 26 實證）** → 在 apply 階段的整合測試中確認：`html content of <incoming message>` 回 error -1728，`html content of <outgoing message>` 回 error -1723 (Access not allowed)。這個權限設計不是實作 bug，是 Apple AppleScript 介面的限制。**實質影響**：reply/forward 非 plain 模式下，`composeReplyHTML` 永遠走 `originalPlain` HTML-escape 路徑，無法保留原信的 HTML 結構（signature 樣式、巢狀 blockquote、inline style 都會降格為 plain text 後再 escape）。**Mitigation**：`buildFetchOriginalContentScript` 用 AppleScript `try/on error` 包住 `html content` 讀取，失敗時回傳空字串，讓 Swift 端自然 fallback 到 plain path。使用者得到的結果仍是合理的（可讀 blockquote），只是格式有損。spec 中新增 Requirement: AppleScript html content read is denied on messages 明確記錄這個行為。
- **[Risk] `html content` 寫入未來 macOS 版本被禁** → **Mitigation**：目前 macOS 26 可寫已實證；加整合測試 gate 以覆蓋 happy path；若未來被禁，保留 plain 模式作 fallback
- **[Risk] `AttributedString(markdown:)` → HTML 產生非預期樣式（SF Pro font, 預設 p.p1 / span.s1 class）** → **Mitigation**：**已改為直接從 AttributedString.runs walk 發 tag**，不經過 `NSAttributedString.data(.html)`，產出乾淨的 `<strong>/<em>/<code>/<a>/<blockquote>/<ul><li>` 結構，無 inline style 污染
- **[Trade-off] Default plain 讓新功能 adoption 較慢** → 可接受；tool description 明確標示
- **[Trade-off] Markdown subset 有限（不支援 table）** → 可接受；若有 caller 需要 table，可改用 `format: "html"` 直接給 pre-rendered HTML
- **[Risk] Concurrent MCP 呼叫同時操作 Mail.app outgoing message** → **Mitigation**：既有程式未處理 concurrency，本 change 亦不引入（維持既有行為）；未來若需要可用 actor 包 `MailController`
