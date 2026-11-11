## 1. 測試先行（RED）

- [x] 1.1 在 `Tests/CheAppleMailMCPTests/MailControllerComposeTests.swift` 加測試，帶標記 `spec-example: message-composition / attachment path kinds`：逐列檢查 Attachment paths must be regular files 的 Example（一般檔案與指向它的 symlink 被接受；目錄、指向目錄的 symlink、`Note.rtfd`、FIFO、`/dev/null` 被拒並帶各自的種類）。驗證：`swift test --filter MailControllerComposeTests` 在實作前失敗。
- [x] 1.2 兩個 Scenario 的測試：FIFO 被拒且不阻塞（不開啟它）、目錄與不存在的路徑在同一個錯誤裡各自列出。驗證：同上，實作前失敗。

## 2. 實作（GREEN）

- [x] 2.1 `MailController.validateAttachmentPaths`：在 deny/allow-list 之後以 `attributesOfItem`（不跟隨最後一段 symlink）讀檔案種類，非一般檔案就加入 `'<path>' rejected: not a regular file (<kind>)`。驗證：1.1、1.2 轉綠，既有 `validateAttachmentPaths` 測試維持綠。

## 3. 文件與交叉紀錄

- [x] 3.1 `CHANGELOG.md` 的 `## [Unreleased]` 加一則條目，寫明行為改變（目錄與 package 目錄被拒）。驗證：內容審閱；`swift test` 全綠。
- [ ] 3.2 在 #479 留言說明 in-process reader 要在開啟後的 descriptor 上再檢查種類，在 #608 留言說明 reply 路徑要呼叫這個 helper。驗證：兩則留言的網址記在 Implementation Complete。
