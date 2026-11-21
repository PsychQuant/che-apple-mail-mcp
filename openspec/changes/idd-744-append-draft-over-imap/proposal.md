## Why

#742（PR #743）讓既有草稿可以經 SMTP 寄出、不經 Mail，但草稿本身仍要靠 Mail 建立：GUI 路徑要開撰寫視窗；opt-in 的直接寫入寫本機資料庫，要 Mail 開著並經觸發才上傳。所以「寫一封信並寄出」還做不到完全不經 Mail。#729 的階段 2 就是補上這一步。

另外，#745 查到 Mail 存的草稿與 Mail 寄出的信版面不同（草稿是 `multipart/alternative`、純文字段是空的、帶草稿專用標頭），`send_draft` 原樣送出 Mail 的草稿會把這些送到收件人手上。由工具自己組的草稿不受這個問題影響。

## What Changes

- 新工具 `append_draft`：對 `direct-transport.json` 列出的帳號，自己組一封單一 `text/plain`（UTF-8）的信，經 IMAP APPEND 放進伺服器標為 `\Drafts` 的信匣，設 `\Draft` 與 `\Seen`。不執行 AppleScript，Mail 不必在執行。
- 結果三種：`appended`、`not_appended`、`unknown`。`unknown` 之後以 Message-ID 查一次草稿匣：查到改報 `appended`，查不到仍是 `unknown`；一律不再 APPEND。
- `send_draft` 多一個選草稿的方式 `message_id`（與 `draft_id`、`subject_match` 三選一），讓 `append_draft` 建的草稿在 Mail 沒開時也能寄出。
- 工具數 60 → 61。

## Non-Goals

- 回覆與轉寄的草稿（串接標頭、引用原文）、附件、rich text、顯示名收件人、簽名。
- 修 #745（`send_draft` 送出 Mail 存的草稿時的版面問題）：那是另一個決定，候選做法列在 #745。
- `create_draft` 的行為不變；`append_draft` 不符條件時不退回任何 Mail 路徑。
- `message-composition` 規格不變：它管經 Mail 的撰寫路徑（GUI 與本機直接寫入）。`append_draft` 不經 Mail，所以它的契約只放在 `direct-transport`。
- 去重紀錄：每次呼叫都是新的 Message-ID，重複呼叫的後果是多一封草稿。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `direct-transport`：新增 `append_draft`；`send_draft` 的選擇器多一個 `message_id`。

## Impact

- Affected specs: `direct-transport`（#742 的 change 尚未封存，這份 delta 疊在它上面）
- Affected code: `Sources/CheAppleMailMCP/DirectTransport/`（新檔 `DraftMessage.swift`、`AppendDraftTool.swift`；`SendDraftFlow.swift`、`SendDraftTool.swift`、`SwiftMailSession.swift`）、`Server.swift`、`ToolAccess.swift`
- Tests: `Tests/CheAppleMailMCPTests/AppendDraftTests.swift`、`SendDraftToolTests.swift`、`SendDraftFlowTests.swift`（替身多一個 `appendDraft`）
- Docs: `README.md`、`README_zh-TW.md`、`CHANGELOG.md`、`mcpb/manifest.json`、`server.json`、`.claude/rules/direct-transport.md`
- 尚未驗證：對真實伺服器的 APPEND；Mail 與其他用戶端是否把這封當成可編輯的草稿。要等維護者同意後只用自己的帳號測。
