## 1. 先寫會失敗的測試（RED）

- [x] 1.1 [P] Refuse reply attachments as a temporary ninth reason（Ineligible composing calls fail without side effects 的第 9 類）：在 `Tests/CheAppleMailMCPTests/ComposeRefusalTests.swift` 加入 `.replyAttachmentsUnsupported` 到 `allRefusals`，並新增測試斷言：訊息單行、含 `#534`、`#608`、`save_as_draft`、`WITHOUT the attachments`、`drag`；`replyForwardRefusal(format:accessibilityTrusted:hasAttachments: true)` 在四種 format／Accessibility 組合下都回傳 `.replyAttachmentsUnsupported`（Check reply attachments before every other pre-flight step）；`hasAttachments: false` 時舊有兩類結果不變。驗證：`swift test --filter ComposeRefusalTests` 在實作前編譯失敗或測試失敗。
- [x] 1.2 [P] 生產端零副作用：在 `ComposeRefusalTests` 新增測試，不設定 `refusalOverride`，以會在被呼叫時 `XCTFail` 的 script runner 呼叫 `MailController.shared.replyEmail(... attachments: [不存在的路徑], saveAsDraft: true)` 與 `saveAsDraft: false`，斷言丟出 `MailError.invalidParameter` 且訊息含 `#608`、script runner 呼叫 0 次、不是「not found」錯誤。驗證：`swift test --filter ComposeRefusalTests` 在實作前失敗。
- [x] 1.3 [P] Guard object-model attachment insertion with a source scan：新增 `Tests/CheAppleMailMCPTests/NoObjectModelAttachmentGuardTests.swift`，比照 `NoBodyInjectionGuardTests` 遞迴掃描 `Sources/CheAppleMailMCP/` 所有 `.swift` 的完整文字，出現 `make new attachment` 即失敗並指向 #534／#608；另加一條確認掃描確實找到檔案（避免空掃描假綠）。驗證：`swift test --filter NoObjectModelAttachmentGuardTests` 在實作前失敗（目前 `ComposeScriptBuilder.swift` 含該字串）。
- [x] 1.4 [P] Keep the attachments parameter and state the refusal in the tool description：更新 `ReplyForwardDisclosureGuardTests`，`reply_email` 說明須含 `Three reasons`、`attachments`、`#608`，且 schema 仍有 `"attachments"` 屬性、其說明含 `refused`；`forward_email` 仍須含 `Two reasons`。驗證：`swift test --filter ReplyForwardDisclosureGuardTests` 在實作前失敗。

## 2. 實作（GREEN）

- [x] 2.1 在 `Sources/CheAppleMailMCP/MailtoCompose.swift` 新增 `ComposeRefusal.replyAttachmentsUnsupported`（文件註解：第 9 類、暫時、只適用 `reply_email`、#608 落地時移除、不得作為類推前例）與其 `message`；`replyForwardRefusal` 新增 `hasAttachments: Bool = false` 並最先檢查。結果：1.1 的測試通過，`forward_email` 的既有測試不變。驗證：`swift test --filter ComposeRefusalTests` 與 `--filter MailtoComposeTests` 通過。
- [x] 2.2 在 `MailController.replyEmail` 最先計算 reply 的 pre-flight 拒絕（`hasAttachments` = `attachments` 非空），拒絕時不做檔案檢查、不跑 script；移除已成為死碼的 `validateAttachmentPaths` 呼叫，不再把 `attachments` 傳給 script builder；`forwardEmail` 傳預設值。結果：1.2 的測試通過。驗證：`swift test --filter ComposeRefusalTests` 通過。
- [x] 2.3 Remove the object-model attachment code instead of leaving it behind the refusal：從 `ComposeScriptBuilder.swift` 移除 `attachmentFragment`、`defaultDelayBetween`／`defaultDelayTrailing`（與 `CHE_MAIL_ATTACHMENT_DELAY_*` 的讀取）、`buildReplyEmailPasteScript` 的 `attachments` 參數、`buildReplyForwardPasteScript` 的 `needsAttachDrain` 參數與附件 drain；改寫檔頭與 Requirement: Composing tools never inject a body via AppleScript 相關的註解，讓整個 `Sources/CheAppleMailMCP/` 不再出現 `make new attachment`。結果：1.3 的守門測試通過，不帶附件的回信 script 不變。驗證：`swift test --filter NoObjectModelAttachmentGuardTests` 與 `--filter MailControllerComposeTests` 通過。
- [x] 2.4 修正 `MailControllerComposeTests` 中斷言舊順序的 `testBuildReplyPasteScript_ccAndAttachments_setNativelyAfterPaste`，改成只帶 cc 的版本（cc 仍在貼上之後、`tell replyMsg` 之內），並斷言 script 不含 `make new attachment`；`testBuildReplyPasteScript_noCcNoAttachments_omitsTellReplyMsgBlock` 隨參數移除調整。驗證：`swift test --filter MailControllerComposeTests` 通過。
- [x] 2.5 把 gated live 測試 `test_replyEmail_asDraft_withCcAndAttachments_succeeds`（`MailAppIntegrationTests`）改成斷言拒絕：不讀 INBOX、不碰 Mail，以 `attachments` 呼叫 `replyEmail` 並斷言丟出含 `#608` 的 `invalidParameter`。驗證：`swift build --build-tests` 編譯通過；此測試受環境變數閘門控制，本 change 不實跑 live。
- [x] 2.6 更新 `Sources/CheAppleMailMCP/Server.swift` 的 `reply_email` 工具說明（Two reasons → Three reasons，列出第三項與 #534／#608）與 `attachments` 參數說明（目前一律拒絕、手動做法），參數保留在 schema。結果：1.4 的測試通過。驗證：`swift test --filter ReplyForwardDisclosureGuardTests` 通過。

## 3. 文件與規格

- [x] 3.1 [P] 兩份規則副本 `.claude/rules/compose-wrapper-free.md` 與 `plugin/rules/compose-wrapper-free.md` 的失敗表一起改：標題與內文由「封閉八類」明文改為九類（第 9 類暫時、只適用 `reply_email`、#608 落地時移除、不得類推），加第 9 列與處置；`README.md` 指向該標題的錨點連結與「eight」敘述同步更新。驗證：`diff` 兩份副本只差 plugin 版的匯入註解；`grep` 確認 README 錨點與新標題一致。
- [x] 3.2 [P] `CHANGELOG.md` 的 `[Unreleased]` 新增 `### Changed` 行為變更條目：`reply_email` 帶附件改為拒絕（原因、手動做法、#534／#608），物件模型附件程式碼移除與新守門測試，`CHE_MAIL_ATTACHMENT_DELAY_BETWEEN`／`_TRAILING` 不再讀取。驗證：內容審閱；`ChangelogParserTests` 通過。

## 4. 驗證

- [ ] 4.1 執行完整 `make test`，記錄每個 suite 的通過數；若 `plugin/tests/test-fda-assist-lifecycle.py` 或 session-start hook 出現負載相關 flake（#605），單獨重跑並記錄兩次結果。驗證：`make test` 結束碼 0。
- [ ] 4.2 確認 `Sources/CheAppleMailMCP/` 無 `make new attachment`、無 `attachmentFragment`、無 `needsAttachDrain`，且 `spectra validate refuse-reply-attachments` 通過。驗證：`grep -rn` 無結果、validate 輸出 valid。
