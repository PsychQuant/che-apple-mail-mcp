## 1. 測試先行（RED）

- [x] 1.1 `Tests/CheAppleMailMCPTests/ForwardSaveAsDraftTests.swift` 的 `testExampleTable`（標記 `spec-example: message-composition / forward_email save_as_draft`）改由 `executeToolCall("forward_email")` 逐列跑 Example 的七列（含省略、`null`、不帶內文），草稿 script 不得含 ⇧⌘D 也不得含 AppleScript `send`，拒絕訊息檢查原因、#673、兩個替代做法與「created and sent nothing」。驗證：handler 改傳 `false` 的突變會讓這個測試轉紅。
- [x] 1.2 `testSchemaAndDescription`：描述提到讀回草稿時確認 To 與內文。驗證：實作前失敗。

## 2. 實作（GREEN）

- [x] 2.1 forward_email can save the forward as a draft — `Server.swift` 的 `forward_email` 描述改為建議讀回草稿的 To 與內文；`mcpb/manifest.json` 重新產生。驗證：1.1、1.2 綠，`ManifestToolsSetEqualityTests` 綠。
- [x] 2.2 `TimeoutOutcomeHint.swift` 的 `.draftSave` 與 `ToolAccess.swift` 的 `.send` doc comment 加上 `forward_email`；`GuiScriptTimeoutTests.swift:360` 的訊息、`WrapperFreeRouteTests.swift` 的 `testForwardPaste_alwaysSend_carriesSentinel` 名稱、`MailControllerComposeTests.swift:413` 的註解改成現在成立的說法。驗證：全套測試綠。

## 3. 文件

- [x] 3.1 `.claude/rules/compose-wrapper-free.md` 與 `plugin/rules/compose-wrapper-free.md`：第 1–9 類屬 GUI 路徑；第 10 類是參數拒絕、不是 GUI 路徑的不合格理由，列在表中只為讓呼叫端查得到處置；plugin 副本的 re-sync 註記加 #599。驗證：兩份除 import 註記外相同。
- [x] 3.2 `plugin/skills/confirmation-protocol/SKILL.md`：寄出的 `forward_email` 移到必須確認；`confirmation-triggers.md` 與 skill 的草稿說明寫明草稿只差一步就寄出、仍要確認收件人與內文、需要含 #599 的 binary（舊 binary 會忽略 `save_as_draft` 而寄出）。驗證：內容審閱。
- [x] 3.3 `README.md` 的錨點與類數、`plugin/CLAUDE.md` 的類數、`.claude/rules/timeout-outcome-boundary.md:97` 的類數；`plugin/CHANGELOG.md` 補上 binary 版本的說明；`CHANGELOG.md` 補上 `null` 與描述的改動。驗證：`make test` 的 plugin 測試綠。
