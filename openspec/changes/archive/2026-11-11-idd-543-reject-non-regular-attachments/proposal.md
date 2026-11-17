## Why

`MailController.validateAttachmentPaths`（#38 的加固）只用 `fileExists` 確認附件路徑存在，再解析 symlink、套用 deny-list 與 `MAIL_MCP_ATTACHMENT_ROOTS` allow-list，從不檢查路徑是什麼種類的檔案。`fileExists` 對目錄、FIFO、裝置檔都回 true，`/dev` 也不在 deny-list，所以 `/dev/zero`、一個目錄或一個 named pipe 會通過每一層（#543）。今天讀附件的是 Mail 本身；#479 計畫讓直接寫入草稿的路徑在本 process 內讀附件 bytes，那時讀 FIFO 會卡住、讀 `/dev/zero` 永不結束，而驗證器會放行兩者。

## What Changes

- `validateAttachmentPaths` 在 symlink 解析與 deny/allow-list 之後，讀取檔案種類（不再跟隨最後一段 symlink），不是一般檔案就把 `'<path>' rejected: not a regular file (<種類>)` 加進既有的 failures 清單；錯誤格式與聚合方式不變。
- **行為改變**：目錄（包括 `.rtfd`、`.app` 這類 package 目錄）、FIFO、socket、字元與區塊裝置，以及解析後仍是 symlink 的路徑，現在都會被拒絕。`compose_email` 與 `create_draft` 兩個呼叫端同時受影響。

## Non-Goals

- 不加檔案大小上限：issue 明說留給 #479 的直接寫入路徑決定。
- 不處理 time-of-check/time-of-use：驗證時的檢查擋不住之後被換掉的路徑；#479 的 in-process reader 必須在開啟後的 descriptor 上再檢查一次（會在 #479 留言說明）。
- 不改 `reply_email`：它目前拒絕所有附件（#534），#608 恢復附件時要接上這個 helper（會在 #608 留言說明）。
- 這是輸入驗證（invalid parameter），與「找不到檔案」「落在 deny-list」同一類；不是 `message-composition` 中封閉的八項不合資格理由之一，不擴充那份清單。

ASSUMPTION: 依 Diagnosis 的預設，目錄也拒絕（issue 的 Expected 寫「not a regular file is rejected」）。若附加資料夾是想要的功能，替代做法是只拒絕 FIFO／socket／裝置並保留目錄；這個選擇列在 cluster PR 的 "Decisions to look at"。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `message-composition`：新增一條 requirement（附件路徑必須是一般檔案）。

## Impact

- Affected specs: `message-composition`（ADDED requirement）
- Affected code: `Sources/CheAppleMailMCP/AppleScript/MailController.swift`（`validateAttachmentPaths`）
- Tests: `Tests/CheAppleMailMCPTests/MailControllerComposeTests.swift`
- Docs: `CHANGELOG.md`（Unreleased）
