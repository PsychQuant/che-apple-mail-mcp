## Why

#599 第 1 輪 verify（https://github.com/PsychQuant/che-apple-mail-mcp/issues/599#issuecomment-6795971978）沒有找到 `save_as_draft: true` 會寄出的路徑，但列了 10 個 in-scope fix：工具層的接線沒有測試（handler 改成傳 `false` 的突變全部測試都沒抓到）、規格寫「非 boolean 一律拒絕」而 `null` 實際上被讀成 `false`、一個 Scenario 說草稿 script「以存檔按鍵結束」不準確、工具描述只叫呼叫端確認草稿內文，以及幾份文件與這次改動不一致。

## What Changes

- 規格：`save_as_draft` 為 `false`、省略或 `null` 時都是 `false`（與 `reply_email` 共用的 `requireBool` 慣例一致）；其他非 boolean 值拒絕。Example 加一列 `null`。Scenario 改為「以存檔按鍵作為送出步驟」。工具描述要建議讀回草稿的收件人與內文。拒絕訊息要寫明原因與兩個替代做法。
- 測試：Example 的每一列改由 `executeToolCall("forward_email")` 跑（含省略、`null`、`true`、不帶內文），草稿 script 不得含 AppleScript 的 `send`，拒絕訊息檢查原因與替代做法；修正已經不成立的測試文字。
- 工具描述：讀回草稿時確認 To 與內文。
- 文件：compose 規則兩份副本把第 10 類寫成參數拒絕、不屬 GUI 路徑的不合格理由；`confirmation-protocol` skill 把寄出的 `forward_email` 移到必須確認，草稿模式的說明寫明仍要確認收件人與內文、需要含 #599 的 binary；README 錨點與類數、`plugin/CLAUDE.md`、`timeout-outcome-boundary.md` 的類數；plugin CHANGELOG 補上「要等下一版 binary 才生效、舊 binary 會忽略 `save_as_draft` 而寄出」；`TimeoutOutcomeHint`、`ToolAccess` 的 doc comment；plugin 規則副本的 re-sync 註記。

## Non-Goals

- `null` 不改成拒絕：`reply_email` 的 `save_as_draft` 用同一個 helper，同一個參數名在兩個工具行為不同更容易出錯；所有決定是否寄出的 boolean 是否改成 null 也拒絕，另議。
- `redirect_email` 的確認層級（#675）、非字串 `body`（#674）、空字串 `body`（#673）都另案處理。
- 真的在 Mail 上跑草稿模式：本輪只有單元測試，見 #599 的 close 條件。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `message-composition`：MODIFIED Requirement: forward_email can save the forward as a draft。

## Impact

- Affected specs: `message-composition`
- Affected code: `Sources/CheAppleMailMCP/Server.swift`（描述）、`Sources/CheAppleMailMCP/TimeoutOutcomeHint.swift`、`Sources/CheAppleMailMCP/ToolAccess.swift`（註解）、`Tests/CheAppleMailMCPTests/ForwardSaveAsDraftTests.swift`、`GuiScriptTimeoutTests.swift`、`WrapperFreeRouteTests.swift`、`MailControllerComposeTests.swift`、`mcpb/manifest.json`
- Docs: `.claude/rules/compose-wrapper-free.md`、`plugin/rules/compose-wrapper-free.md`、`.claude/rules/timeout-outcome-boundary.md`、`plugin/rules/confirmation-triggers.md`、`plugin/skills/confirmation-protocol/SKILL.md`、`plugin/CLAUDE.md`、`plugin/CHANGELOG.md`、`README.md`、`CHANGELOG.md`
