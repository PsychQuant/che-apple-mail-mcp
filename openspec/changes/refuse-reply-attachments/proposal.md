## Problem

`reply_email` 帶非空的 `attachments` 時，回傳 `Reply saved as draft (paste path)`（送出模式則是 `Reply sent successfully (paste path)`），但存下的草稿只剩附件與簽名：剛貼上的新內文與 Mail 自己建的引用原信都不見了。2026-10-21／22 一個 session 內三次、#461 的兩次、以及 2026-11-01 的對照實驗（同一封信、同一條路徑，只差 `attachments`）都是同一個結果。不帶附件時內文與引用都完整保留。送出模式用同一份 script，推斷會寄出只有附件的回信（未重現）。結果字串無法分辨這種情況與真正的成功（#534）。

## Root Cause

回信 script 在 ⌘V 貼上新內文之後，對回信的 `outgoing message` 物件執行 `make new attachment with properties {file name:…} at after the last paragraph`（由 `attachmentFragment` 產生）。依 Mail 的 scripting dictionary，`attachment` 是 `content`（rich text）的元素，`the last paragraph` 是 `content` 的段落，所以這個指令是寫入 `content`。物件模型的 `content` 既沒有 `reply` 動詞建的引用，也沒有經編輯器貼上的內文（#43），寫入後整份文件只剩附件，再由 FB11734014 的同一條序列化路徑包上 `Apple-Mail-URLShareWrapperClass` ／ `blockquote type="cite"`。這是 #218 把內文改成 GUI 貼上、卻把附件留在物件模型時引入的（590f58a）。

既有守門測試只檢查三種字面形式（`set content to`、`set html content to`、`make new outgoing message` 裡的 `content:`），元素插入 `content` 是第四種形式，沒有被擋到；單元測試還把錯誤的順序當成預期行為斷言。

## Proposed Solution

第一階段（本 change）：先讓錯誤的成功回報不可能發生，附件回信由第二階段（#608）處理。

- `reply_email` 收到非空 `attachments` 時，在任何 AppleScript、GUI 操作或檔案檢查之前就拒絕，零副作用，錯誤訊息具名原因並給出手動替代做法（不帶 `attachments`、`save_as_draft: true` 存成草稿，再把檔案拖進 Mail 的撰寫視窗），並指向 #608。草稿與送出模式都拒絕。
- `message-composition` spec 的封閉清單由「exactly the following eight」**明文改成** nine，第九類寫成暫時性、只適用 `reply_email`，並寫明 #608 落地時移除；不以類推方式延伸。同一份 spec 的「never inject a body」requirement 把元素插入 `content`（`make new attachment`）列為禁止形式。
- 從 `ComposeScriptBuilder.swift` 移除 `attachmentFragment` 與物件模型附件指令，以及其唯一呼叫處與因此變成死碼的參數、延遲常數與附件 drain。新增守門測試：`Sources/CheAppleMailMCP/` 下任何檔案出現 `make new attachment` 即失敗。
- 修正斷言舊順序的單元測試，並把只檢查成功字串的 gated live 測試改成斷言拒絕。
- `reply_email` 的工具說明與 `attachments` 參數說明改為「目前會被拒絕，以及原因」；參數保留在 schema，讓呼叫得到具名拒絕而非 schema 錯誤。
- 兩份 repo 內的規則副本（`.claude/rules/compose-wrapper-free.md`、`plugin/rules/compose-wrapper-free.md`）的失敗表一起加第九列；全域鏡像在另一個 repo，由維護者更新。
- `CHANGELOG.md` 的 Unreleased 記為行為變更。

## Non-Goals (optional)

- 透過 Mail 編輯器附加檔案（⇧⌘A）、CJK 路徑的附件回信：屬第二階段 #608。
- `forward_email`：目前沒有 `attachments` 參數，沒有要修的附件路徑。
- #461 的 frontmost 缺口（⌘V 可能落在其他 app）：另案處理。
- 修改全域鏡像 `che-claude-config/rules/common-mail-compose.md`：位於另一個 repo。
- 任何 live 執行（不碰 Mail）。

## Success Criteria

- `reply_email` 帶一個以上附件時（草稿與送出皆然），回傳 `MailError.invalidParameter`，訊息含原因、手動替代做法與 #608，且沒有執行任何 script。
- 不帶附件的 `reply_email` 行為與產生的 script 不變（除了不再有空的附件分支）。
- `Sources/CheAppleMailMCP/` 不再含 `make new attachment`，新的守門測試在它出現時會轉紅。
- spec 的封閉清單明文為九類，第九類標示暫時與退場條件；`spectra validate` 通過。
- `make test` 全綠。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `message-composition`: 封閉的不合格原因清單由八類明文改為九類（第九類暫時、只適用 `reply_email` 帶附件，#608 落地時移除）；禁止以 AppleScript 注入內文的 requirement 把元素插入 `content`（`make new attachment`）列為禁止形式

## Impact

- Affected specs: `message-composition`（兩個 requirement：Ineligible composing calls fail without side effects；Composing tools never inject a body via AppleScript）
- Affected code:
  - `Sources/CheAppleMailMCP/AppleScript/ComposeScriptBuilder.swift`
  - `Sources/CheAppleMailMCP/MailtoCompose.swift`
  - `Sources/CheAppleMailMCP/AppleScript/MailController.swift`
  - `Sources/CheAppleMailMCP/Server.swift`
  - `Tests/CheAppleMailMCPTests/`（`ComposeRefusalTests`、`MailControllerComposeTests`、`MailAppIntegrationTests`、`ReplyForwardDisclosureGuardTests`、新增 `NoObjectModelAttachmentGuardTests`）
  - `.claude/rules/compose-wrapper-free.md`、`plugin/rules/compose-wrapper-free.md`、`README.md`（規則錨點連結）
  - `CHANGELOG.md`
