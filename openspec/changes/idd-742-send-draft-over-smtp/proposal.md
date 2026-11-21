## Why

寄信目前只能經 Mail：用鍵盤按鍵送出、沒有可靠的回條（#700 回報寄出但沒寄出），Mail 要開著、要開視窗、要 Accessibility。沒有任何工具能寄出一封既有的草稿（#716 的第二階段）。#729 定了方向：寫入首選直接對郵件伺服器操作，Mail 不必在執行；憑證先用一個帳號試點；第一類先做寄送。

## What Changes

- 新工具 `send_draft`：把**一封已經在伺服器草稿匣裡的草稿**經 SMTP 寄出。只接受帳號與草稿的選擇參數，不能寫內容。不執行 AppleScript，Mail 不必在執行。
- 新的 capability `direct-transport`：帳號設定檔、憑證（這個 server 自己的 keychain 項目）、SMTP 提交、寄件備份補存、草稿移除、已寄出紀錄。
- 結果分階段回報：提交（已提交／沒寄出／結果未知）、寄件備份、草稿移除各自一個狀態。提交之後的階段失敗，再呼叫一次只補做未完成的階段，不重寄。
- 新的命令列模式，讓維護者把憑證從 stdin 存進 keychain，以及清掉一筆「結果未知」的紀錄。這兩件事不做成 MCP 工具，agent 不能自己做。
- **BREAKING**：最低系統從 macOS 13 提高到 macOS 26。`SwiftMail` 要求 macOS 15；而目標低於 26 時，release 的 binary 會硬性載入 macOS 15 沒有的 `libswiftCompatibilitySpan.dylib`。
- 加入相依 `Cocoanetics/SwiftMail`（釘在 1.17.0 那個 tag 的 commit）；`Package.resolved` 開始納入版本控制。

## Non-Goals

- 撰寫工具改成只存草稿、不寄出（#716 的第一階段）。
- 不經 Mail 建立草稿、或把草稿放上伺服器（#729 的階段 2）。這次只寄**已經在伺服器上**的草稿。
- Gmail（OAuth）、Exchange，以及第二個帳號。
- 標記、搬移、刪除（#729 的階段 3）。
- 寄出失敗時退回 GUI 路徑。兩條路徑不互相替補。

## Capabilities

### New Capabilities

- `direct-transport`：不經 Mail、直接對郵件伺服器操作的寫入路徑；這次只含寄出既有草稿。

### Modified Capabilities

（無）

## Impact

- Affected specs: `direct-transport`（新增）
- Affected code: `Package.swift`、`Sources/CheAppleMailMCP/DirectTransport/`（新目錄）、`Sources/CheAppleMailMCP/Server.swift`（一個新工具）、`Sources/CheAppleMailMCP/ToolAccess.swift`、`Sources/CheAppleMailMCP/RunMode.swift` 與 `main.swift`（命令列模式）
- Tests: `Tests/CheAppleMailMCPTests/DirectTransport*Tests.swift`
- Docs: `README.md`、`README_zh-TW.md`、`CHANGELOG.md`、`mcpb/manifest.json`、`.claude/rules/r-must-direct-db.md`、`.claude/rules/timeout-outcome-boundary.md`、新的 `.claude/rules/direct-transport.md`
- 相依：從 7 個套件變成 24 個（SwiftNIO、NIOSSL、swift-crypto 等）。
- 尚未驗證：對真的 iCloud 伺服器的連線與寄送。要等維護者設好憑證並同意後，只寄給他自己。
