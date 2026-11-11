## Why

`forward_email` 沒有存成草稿的模式：不帶內文與帶內文兩條路都直接寄出（#599）。寄出不可逆，要先確認才能寄的 agent 因此完全不能用這個工具；`reply_email` 早有 `save_as_draft`（#33）。工具描述也沒有說這個呼叫會寄出。

## What Changes

- `forward_email` 新增 `save_as_draft`（boolean，預設 false，非 boolean 拒絕）。帶內文時沿用同一條 paste 路徑，最後按 ⌘S 存成草稿而不寄出，成功訊息為 `Forward saved as draft (paste path)`。
- 不帶內文卻 `save_as_draft: true`：在任何 Mail 動作之前以具名原因拒絕（暫時，#673 以後移除）。不帶內文的轉寄是 Mail 原生 `forward` 加 `send`，沒有按鍵，拿掉 `send` 只會留下沒存的視窗。
- 不帶 `save_as_draft` 時行為不變（寄出）。寄出路徑的逾時判斷一字不改；存草稿那條路的逾時不回報成「寄送狀態未知」，而是走存草稿的提示（與 `reply_email` 的草稿模式相同）。
- 工具描述第一句說明：沒有 `save_as_draft: true` 就會寄出；存成草稿後先讀回確認內文（#461）；帶內文的草稿模式還沒有在 Mail 上實跑過。
- `compose-wrapper-free.md`（repo 規則與 plugin 副本）的封閉失敗表加上暫時的第十列；`confirmation-triggers.md`、`confirmation-protocol` skill、README、兩份 CHANGELOG。

## Non-Goals

- 不帶內文的草稿模式（#673）。
- 不改寄出路徑的任何行為與訊息。

ASSUMPTION: 依 Diagnosis decision 1 的預設 (c)：先做帶內文的草稿模式，不帶內文時具名拒絕；全域鏡像 `che-claude-config/rules/common-mail-compose.md` 在 repo 外，列為待補。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `message-composition`：ADDED Requirement: forward_email can save the forward as a draft。

## Impact

- Affected specs: `message-composition`
- Affected code: `Sources/CheAppleMailMCP/Server.swift`（schema、description、handler）、`Sources/CheAppleMailMCP/AppleScript/MailController.swift`（`forwardEmail`）、`Sources/CheAppleMailMCP/AppleScript/ComposeScriptBuilder.swift`（`buildForwardEmailPasteScript`）
- Tests: `Tests/CheAppleMailMCPTests/ForwardSaveAsDraftTests.swift`
- Docs: `.claude/rules/compose-wrapper-free.md`、`plugin/rules/compose-wrapper-free.md`、`plugin/rules/confirmation-triggers.md`、`plugin/skills/confirmation-protocol/SKILL.md`、`README.md`、`CHANGELOG.md`、`plugin/CHANGELOG.md`
