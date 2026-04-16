## 1. Scaffolding

- [x] 1.1 建立 `Sources/CheAppleMailMCP/MarkdownRendering.swift`，內含 `BodyFormat` enum (`plain` / `markdown` / `html`) 與 `ComposedBody` struct — 實踐 "Markdown rendering is encapsulated in a helper module" 設計決策
- [x] 1.2 在 `BodyFormat` 上新增 `init?(rawValueOrNil:)` 解析 helper，nil/空字串回傳 `.plain`（實踐 Default format is "plain" for backwards compatibility 設計決策）

## 2. 撰寫失敗測試（TDD RED）

- [x] 2.1 `Tests/CheAppleMailMCPTests/MarkdownRenderingTests.swift` 新檔：測試 markdown 粗體、斜體、inline code、連結渲染（覆蓋 "Markdown mode renders via AttributedString" 需求與 "Markdown parsing via Swift-native AttributedString(markdown:)" 設計決策）
- [x] 2.2 MarkdownRenderingTests 擴充：測試 plain content 在 blockquote 內的 HTML escape（覆蓋 "Reply and forward preserve original content in HTML modes" 需求）
- [x] 2.3 MarkdownRenderingTests 擴充：malformed markdown 觸發 parse error（覆蓋 "Markdown parse failure surfaces as tool error" scenario）
- [x] 2.4 [P] `Tests/CheAppleMailMCPTests/BodyFormatTests.swift` 新檔：`BodyFormat` 解析拒絕無效 raw value（覆蓋 "Invalid format value is rejected" scenario 與 "Composing tools accept a format parameter" 需求）
- [x] 2.5 執行 `swift test`，確認 group 2 所有測試都 fail（TDD RED 階段）

## 3. 實作 MarkdownRendering 模組

- [x] 3.1 實作 `renderBody(_:format:)` 函式，回傳 `ComposedBody`。`markdown` → `AttributedString(markdown:)` → 自行 walk runs 產生 HTML（NSAttributedString `.html` 寫出不保留 inline intent，改為直接 walk runs）；`html` → 原樣放入 `htmlContent`；`plain` → `htmlContent` 為 nil、`plainContent` 為原始 body（實踐 "AppleScript html content property as the rendering target" 設計決策）
- [x] 3.2 實作 HTML escape helper（覆蓋 `<`、`>`、`&`、`"`、`'`），用於 plain 原信內容塞進 blockquote 的路徑
- [x] 3.3 重新執行 `swift test`，group 2 所有測試改為 PASS（TDD GREEN）

## 4. 更新 MailController — compose 與 draft

- [x] 4.1 `composeEmail` 方法簽章新增 `format: BodyFormat = .plain` 參數；`.plain` 維持既有 `content:` 寫法；`.markdown`/`.html` 走 `html content` property 寫入（覆蓋 "Plain mode preserves existing behavior"、"HTML mode writes body to AppleScript html content" 需求）
- [x] 4.2 `createDraft` 方法以相同方式新增 `format` 參數與分支邏輯
- [x] 4.3 新增 `Tests/CheAppleMailMCPTests/MailControllerComposeTests.swift`：以「擷取 AppleScript 字串而非實際執行」的方式，測試 `composeEmail` / `createDraft` 在 plain / markdown / html 三種 format 下生成的 script 包含正確的 property 設定

## 5. 更新 MailController — reply 與 forward 的 blockquote 合併

- [x] 5.1 `replyEmail` 方法簽章新增 `format` 參數；`.plain` 維持 `& return & return & content`；`.markdown`/`.html` 走 `html content` 並以 `<blockquote>` 包覆原信（優先用 `html content of originalMsg`，失敗時 fallback 用 HTML-escaped `content of originalMsg`）— 實踐 "Reply/forward merges original content via HTML blockquote" 設計決策
- [x] 5.2 `forwardEmail` 以相同方式處理
- [x] 5.3 `MailControllerComposeTests` 擴充：reply/forward × 3 format 的 script 產出驗證，非 plain 模式下 AppleScript 必須包含 `html content` property 與 `<blockquote>` 片段（覆蓋 "Reply and forward wrap original content in HTML blockquote" 需求）

## 6. 更新 Server.swift — schema 與 handler dispatch

- [x] 6.1 `compose_email`、`create_draft`、`reply_email`、`forward_email` 四個 tool 的 `inputSchema` 新增 `format` 屬性，`enum: ["plain", "markdown", "html"]`，不列入 `required`（覆蓋 "Composing tools input schema exposes format parameter" 需求、"Format parameter symmetry with getEmail read path" 設計決策）
- [x] 6.2 handler dispatch 讀取 `arguments["format"]?.stringValue`，透過 `BodyFormat(rawValueOrNil:)` 轉成 `BodyFormat` 並傳入對應 `MailController` 方法
- [x] 6.3 無效 `format` 值回傳 MCP error，訊息列出三個合法值（覆蓋 "Invalid format value is rejected" scenario）
- [x] 6.4 `Tests/CheAppleMailMCPTests/ServerSchemaTests.swift` 新增或擴充：`tools/list` 回傳中，四個 composing tool 都宣告 format enum 為 `["plain", "markdown", "html"]` 且非 required（覆蓋 "Tool schema advertises format enum" scenario）

## 7.4 Verify findings remediation（來自 /idd-verify #15）

- [x] 7.4.1 P1 修復：`attributedStringToHTML` 改用 `PresentationIntent` identity-based flush，修復 adjacent same-kind block 合併 bug（multi-paragraph / adjacent list items）
- [x] 7.4.2 新增 4 個多段 / list 測試：`testRenderBody_markdown_twoParagraphs_producesTwoPTags`、`testRenderBody_markdown_orderedList_threeItems_produceThreeLi`、`testRenderBody_markdown_paragraphThenList_producesUlAndTwoLis`、`testRenderBody_markdown_listThenParagraph_separatesCorrectly`、`testRenderBody_markdown_twoOrderedLists_separated_countItemsCorrectly`
- [x] 7.4.3 新增 `parseBodyFormatArgument(Value?)`: 處理 MCP Value 型別，拒絕非 string（如 int/bool）並丟 MailError.invalidParameter，相容 `.null` 為 `.plain`。4 個 handler dispatch 改呼此函式
- [x] 7.4.4 新增 3 個 Value 型別測試：nil → .plain、.string 正常、.int(42) / .bool(true) → 拒絕
- [x] 7.4.5 Spec 新增 Requirement "Signature preservation is out of scope"（覆蓋 #15 Required Support #3 誠實定位為 partial — 簽名保留需要不同架構如 MailKit extension）

## 7.5 Integration testing（E2E against real Mail.app）

- [x] 7.5.1 Spec 修正：新增 Requirement "AppleScript html content read is denied on messages" 與對應 scenario，反映 apply 階段發現的 AppleScript 權限限制（incoming msg -1728 / outgoing msg -1723）
- [x] 7.5.2 Design 修正：Risks 段落記錄此為系統層級限制（非實作 bug），`composeReplyHTML` 永遠走 `originalPlain` escape 路徑；保留 `try/on error` 讓未來 macOS 放寬後自動生效
- [x] 7.5.3 `Tests/CheAppleMailMCPTests/MailAppIntegrationTests.swift` 新檔：gated by `MAIL_APP_INTEGRATION_TESTS=1` 的 4 個 integration tests — createDraft × 3 format 真的在 Mail.app Drafts 建 draft、`html content of inbox` 被 AppleScript 拒絕的行為實證，tearDown 自動清理 subject 前綴為 `INTEGRATION-TEST-format-param-` 的 draft
- [x] 7.5.4 驗證 `MAIL_APP_INTEGRATION_TESTS=1 MAIL_INTEGRATION_ACCOUNT_NAME=Google swift test --filter MailAppIntegrationTests` 4 tests pass against macOS 26 / Mail 16

## 7. 文件與發佈

- [x] 7.1 `CHANGELOG.md` 新增 `## [Unreleased]` 段落，記錄 `format` 參數新增與 #14 / #15 關閉
- [x] 7.2 更新四個 composing tool 的 `description`，明確標示「default format is 'plain'; set format to 'markdown' or 'html' for rich text」— 讓 MCP 客戶端自動看到
- [x] 7.3 執行 `swift build -c release` 與 `swift test`，全部通過（201 tests, 0 failures, 1 skipped）；實際 release（`./scripts/release.sh vX.Y.Z`）留給使用者決定版本號後手動觸發，per CLAUDE.md release process
