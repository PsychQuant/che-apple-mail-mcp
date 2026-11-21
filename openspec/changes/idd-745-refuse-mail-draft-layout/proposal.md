## Why

`send_draft`（#742）把伺服器上的草稿原樣送出，只去掉 Bcc。Mail 存的草稿是 `multipart/alternative`、純文字段是空的、帶草稿專用標頭（`X-Uniform-Type-Identifier: com.apple.mail-draft` 等）；Mail 寄出時會重組成另一個形狀（#745 的唯讀比對）。原樣送出，收件人會收到空的純文字段與草稿標頭。

## What Changes

- 提交前的檢查加第 6 項：草稿帶 Mail 的草稿標記（`X-Uniform-Type-Identifier: com.apple.mail-draft`）就拒絕，不開 SMTP、不寫紀錄；訊息說明可以用 `append_draft`（#744）建一封能原樣寄出的草稿，或在 Mail 裡寄。
- 已提交、只剩收尾階段的草稿不受影響，照常補做。

## Non-Goals

- 把 Mail 的草稿重組成 Mail 寄出的形狀（#745 的做法 C）。那要改寫內容（HTML 轉純文字），需要另外的規格；可以疊在這次上面另開 issue。
- 從 MIME 結構推測版面。只認 Mail 自己寫的標記，避免誤擋別的用戶端的正常信。

## Capabilities

### Modified Capabilities

- `direct-transport`：提交前的檢查多一項。

## Impact

- Affected specs: `direct-transport`（修改 #742 的「A draft is checked before it is submitted」）
- Affected code: `Sources/CheAppleMailMCP/DirectTransport/SendDraftFlow.swift`、`SendDraftTool.swift`（說明）
- Tests: `Tests/CheAppleMailMCPTests/SendDraftFlowTests.swift`
- Docs: `README.md`、`README_zh-TW.md`、`CHANGELOG.md`、`mcpb/manifest.json`、`.claude/rules/direct-transport.md`
