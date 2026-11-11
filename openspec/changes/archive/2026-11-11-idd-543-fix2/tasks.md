## 1. 測試先行（RED）

- [x] 1.1 更新 `testValidateAttachmentPaths_dotDotAfterALinkCountsFromTheLinkTarget` 與 `testValidateAttachmentPaths_allowListJudgesTheKernelTarget`（標記 `spec-example: message-composition / attachment path kinds`）：含 `..` 的路徑（絕對、相對、`./`）被拒為 `contains a '.' or '..' path component`；同一個檔不含 `..` 時被接受；經 link 而不含 `..` 的路徑仍由 allow-list 判斷 link 的目標。驗證：實作前失敗。
- [x] 1.2 新增 `testValidateAttachmentPaths_dotNamesAndTrailingSlash`（同一標記）：`.hidden.txt`、`a..b.txt`、`...txt` 被接受，`report.txt/` 為 not found，`dir/./report.txt` 被拒。驗證：實作前失敗。
- [x] 1.3 `testNonRegularFileKind_namesEveryKind`（標記 `spec-example: message-composition / attachment type names`）加上 `/dev/disk0` → block device。驗證：通過。

## 2. 實作（GREEN）

- [x] 2.1 Attachment paths must be regular files — `validateAttachmentPaths`：在任何檢查之前拒絕 `.`／`..` 段；doc comment 改為照實描述存在檢查用原始路徑。驗證：1.1、1.2 轉綠，`MailControllerComposeTests` 全綠。
- [x] 2.2 `FifoReaderProbe` 的註解寫明它抓得到與抓不到的情況。驗證：內容審閱。

## 3. 文件

- [x] 3.1 SECURITY.md：第 0 層、§1 存在檢查、§2、TOCTOU 時間窗、章節開頭的 `update_draft`、Known limitations（字串前綴、hard link、#671、#669）；CHANGELOG 修正過度宣稱並寫明新的拒絕。驗證：內容審閱。
