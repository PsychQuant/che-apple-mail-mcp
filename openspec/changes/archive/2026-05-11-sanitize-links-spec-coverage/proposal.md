## Why

#19 在 cluster A (PR #81) 出貨了 `sanitize_links` opt-in URL allowlist 給 markdown mode,但留下兩個 P2 完成度缺口:

1. **Spec gap**:`openspec/specs/message-composition/spec.md` 沒有任何 Requirement / Scenario codify 這個安全行為。`grep -i sanitize openspec/specs/message-composition/spec.md` 回 0 hits。Issue #19 列出的三個 deliverable 中,「Doc」項目只更新了 tool descriptions,沒更新 formal spec。
2. **Wiring gap**:5 個 unit tests 在 `MarkdownRenderingTests` 直接測 `renderBody(sanitizeLinks:)`,**zero** test pin 整條鏈 `MCP arguments → Server.swift handler → MailController → ComposeScriptBuilder → renderBody`。Devil's Advocate 在 verify 階段實證:把 `sanitizeLinks: sanitizeLinks` forwarding 從 5 個 sites 任一拿掉,309 個 test 全部繼續通過 — security feature 變成 silent no-op。

兩個 gap 都是 P2 regression-prevention,在下個 release tag (v2.8.x) 之前 close 掉,把已出貨的安全行為鎖成正式 contract。

## What Changes

純 doc + test 改動,**沒有 production code 行為變更**。

- **Spec 端 (Gap B)**:在 `openspec/specs/message-composition/spec.md` 新增 1 個 Requirement (allowlist 行為 + default-off + mode-restriction) + 3 個 Scenarios (default-off passthrough、`sanitize_links=true` 阻擋 javascript:、`sanitize_links=true` 保留 http/https/mailto/tel)。
- **Test 端 (Gap A)**:在 `Tests/CheAppleMailMCPTests/MailControllerComposeTests.swift` 新增 4 個 wiring contract tests,每個對應一個 composing tool (`compose_email`、`create_draft`、`reply_email`、`forward_email`),透過 `assertOrdered` pattern 直接斷言:`sanitize_links=true` 時產生的 AppleScript 不含 `href="javascript:` , `sanitize_links=false` 時 (default) 仍含 — 兩臂都 pin 住,防止單側 silent regression。
- **Tasks**:沒有跨檔案 dependency,可單一 PR 一次 land。

## Non-Goals (optional)

- 不更動 `sanitize_links` allowlist 內容 (保留 `{http, https, mailto, tel}`)
- 不改 schema description (那是 #86 的範圍)
- 不引入 default-on (#19 的 Scope 3 「Safe-by-default」當時 conscious deferred,本 change 不重新 open 該 trade-off)
- 不加 allowlist tripwire test / bypass-class regression test 套組 (那是 #87 的 grab-bag)

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `message-composition`: 新增 Requirement: "Markdown mode honors opt-in URL scheme allowlist via `sanitize_links`",codify 已出貨 (commit `4ef4dc3`) 的行為 contract。

## Impact

- **Affected specs**: `openspec/specs/message-composition/spec.md` (1 new Requirement block + 3 Scenarios)
- **Affected code**:
  - `Tests/CheAppleMailMCPTests/MailControllerComposeTests.swift` (4 new wiring contract tests)
- **Affected APIs**: 無 (純 doc + test)
- **Affected dependencies**: 無
- **Affected runtime behavior**: 無 — 全部是 regression-prevention,既有 309 tests 不受影響
