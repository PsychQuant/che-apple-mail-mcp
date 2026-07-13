# Tasks — rename-export-tool-batch-alias

## 1. 雙註冊與 deprecation 行為（Server.swift）

- [x] 1.1 `Sources/CheAppleMailMCP/Server.swift`：tool list 新增 `batch_export_emails_markdown` entry — 沿用現行 export 完整 description（含 #236 併發契約與 #177 dedup 說明）與完整 inputSchema；驗證：schema 測試斷言兩名的 inputSchema 深度相等
- [x] 1.2 `Sources/CheAppleMailMCP/Server.swift`：既有 `export_emails_markdown` entry 的 description 改為以 `DEPRECATED — renamed to batch_export_emails_markdown; this alias will be removed in the next major release (v3.0).` 開頭（原內容保留於其後）；驗證：guard test 斷言 deprecated 前綴存在且 canonical entry 不含 DEPRECATED
- [x] 1.3 `Sources/CheAppleMailMCP/Server.swift`：dispatch 改為 `case "export_emails_markdown", "batch_export_emails_markdown":`，並在舊名分支輸出一行 stderr deprecation warn（含 canonical 名；結果內容不變）；驗證：單元測試斷言兩名路由同 handler（藉由 handler 回傳一致），stderr warn 訊息由 pure helper 組字並測試

## 2. 測試（TDD — 先 RED 後實作）

- [x] 2.1 新增/擴充 schema 一致性測試：`batch_export_emails_markdown` 與 `export_emails_markdown` 的 inputSchema JSON 完全相等、description 前綴契約（canonical 無 DEPRECATED / alias 有）；驗證：`swift test --filter <測試名>` 綠
- [x] 2.2 deprecation warn 訊息 pure helper 測試（含 canonical 名、單行）；驗證：filter 測試綠
- [x] 2.3 全套件迴歸：`swift test` 0 failures；驗證：完整輸出 `Executed N tests, 0 failures`

## 3. 文件

- [x] 3.1 [P] `README.md`：Batch/Export 工具表加 `batch_export_emails_markdown` 行、舊名行標 deprecated；工具計數統一為實測 51（原估 49 — verify round 修正；同時修正既有 47/48 不一致）；驗證：內容審閱 + grep 計數字樣
- [x] 3.2 [P] `CHANGELOG.md` [Unreleased] Added 段：rename + deprecated alias + v3.0 移除 gate + caller 遷移指引（archive-mail SOP 於 distribution sync 改名）；驗證：內容審閱
