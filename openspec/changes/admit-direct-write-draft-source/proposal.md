## Why

`main` 上 #472 的 opt-in 直接寫入原型（`CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1`）已經和 `message-composition` spec 不一致：spec 規定 compose 工具的內文 **exclusively** 來自 Mail 自己的編輯器，而直接寫入是自組 MIME、寫進 Mail 的本機資料庫，是第三種來源。它不是 AppleScript 注入，但 spec 目前沒有任何地方承認它，也沒有可測的契約描述它。v3.3.0 若在 spec 修正前發版，會把這個不一致一起發出去（#475，epic #473）。

同時，`create_draft` 現在有三條可能的路徑（直接寫入成功、直接寫入失敗後退回 GUI、不符條件直接走 GUI），但 #464 的計時 CSV 只量得到 GUI 那一條，而且沒有欄位標示路徑。#481（預設化）需要兩條路徑的實測差距作為依據。

## What Changes

- 修改 `message-composition` 的 requirement「Composing tools never inject a body via AppleScript」：AppleScript 注入禁令一字不改；body 來源從「只能來自 Mail 的編輯器」改成兩種，另一種是 `create_draft` 在 opt-in 下自組 MIME、直接寫入本機資料庫。
- 在 `message-composition` 新增 requirement「Direct-write draft path」，把 #472 已出貨的行為寫成契約：opt-in 環境變數、10 類不符條件的封閉列舉、Mail／macOS 版本閘門與資料庫結構閘門、單一寫入交易、觸發前失敗精確還原並退回 GUI、觸發後不退回、退回時結果附原因。
- 新增 capability `compose-timing`：把 #464 的 GUI 計時補成 spec，並擴充到 `create_draft` 的三條路徑。
  - CSV 新增最後一欄 `path`（`direct`／`gui-mailto`）。
  - `create_draft` 的一次呼叫只有一個 `run_id`；直接寫入失敗後退回 GUI 時，兩段的列共用同一個 `run_id`、同一個起點。
  - 直接寫入路徑的 `outcome` 欄記固定代碼（例如 `created`、`not_attempted:ccOrBcc`、`fell_back:trigger`），不放含逗號的原因全文。
  - 既有 CSV 的表頭和新表頭不同時不寫入，並在 stderr 說明。
- 三份 compose 規則（`.claude/rules/compose-wrapper-free.md`、全域鏡像 `che-claude-config/rules/common-mail-compose.md`、`plugin/rules/compose-wrapper-free.md`）的〈現況〉表各加一列說明 opt-in 直接寫入；六類失敗對照表不變。
- 不改任何 compose 行為：不放寬 `format`、顯示名、Accessibility 失敗類別，也不改直接寫入的適用條件。

## Capabilities

### New Capabilities

- `compose-timing`: opt-in 的 compose 逐步計時 CSV，涵蓋 GUI mailto 路徑與 `create_draft` 的直接寫入路徑，含 `path` 欄、跨段共用 `run_id`、表頭不符時拒寫。

### Modified Capabilities

- `message-composition`: body 來源的 requirement 承認 opt-in 直接寫入；新增「Direct-write draft path」requirement。

## Impact

- Affected specs: `message-composition`（MODIFIED 1 條、ADDED 1 條）、`compose-timing`（新）
- Affected code:
  - `Sources/CheAppleMailMCP/AppleScript/ComposeTiming.swift`（`path` 欄、run context、表頭檢查）
  - `Sources/CheAppleMailMCP/AppleScript/MailController.swift`（`recordComposeTiming` 在 run 內改為交給 run）
  - `Sources/CheAppleMailMCP/DirectDraft/DirectDraftPath.swift`（各步驟計時點、outcome 代碼）
  - `Sources/CheAppleMailMCP/Server.swift`（`create_draft` handler 包住整次呼叫的 run）
  - `Tests/CheAppleMailMCPTests/ComposeTimingTests.swift`、`DirectDraftPathTests.swift`
  - 三份 compose 規則、`CHANGELOG.md`
