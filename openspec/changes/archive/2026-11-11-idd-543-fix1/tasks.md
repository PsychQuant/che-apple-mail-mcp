## 1. 測試先行（RED）

- [x] 1.1 `testValidateAttachmentPaths_dotDotAfterALinkCountsFromTheLinkTarget` 與 `testValidateAttachmentPaths_allowListJudgesTheKernelTarget`，帶標記 `spec-example: message-composition / attachment path kinds`：`a/L/../target.txt`（絕對與相對）被接受、有 decoy 的 `a/L/../pipe` 被拒為 FIFO、`allowed/L/../secret.txt` 被 allow-list 拒絕。驗證：實作前失敗。
- [x] 1.2 `testNonRegularFileKind_namesEveryKind`，帶標記 `spec-example: message-composition / attachment type names`：socket、symbolic link、character device、讀不到的種類。驗證：實作前失敗（舊標籤 `unreadable type`）。
- [x] 1.3 `testUpdateDraft_rejectsANonRegularAttachmentBeforeAnyMailScript`：任何 Mail script 執行就失敗。驗證：實作前失敗（定位掃描先跑）。
- [x] 1.4 FIFO 測試改成有界：`FifoReaderProbe` 以非阻塞寫端偵測是否有人開啟讀端。驗證：把 `open(path, O_RDONLY)` 插進種類檢查的 mutation 會讓測試失敗而不是卡住。

## 2. 實作（GREEN）

- [x] 2.1 Attachment paths must be regular files — `validateAttachmentPaths`：先轉絕對路徑，再只用 `resolvingSymlinksInPath()` 解析；doc comment 移回函式上並列出五層。驗證：1.1 轉綠，既有 deny-list／allow-list／`/tmp` 測試維持綠。
- [x] 2.2 `nonRegularFileKind`：讀不到種類時回 `type could not be read`。驗證：1.2 轉綠。
- [x] 2.3 `updateDraft`：在定位掃描之前驗證附件。驗證：1.3 轉綠。

## 3. 文件與交叉紀錄

- [x] 3.1 SECURITY.md §2、§5、TOCTOU、歷史列順序；CHANGELOG 寫明 `update_draft` 與 `..` 解析。驗證：內容審閱。
- [x] 3.2 在 #479 補一則更正：`O_NOFOLLOW` 要用在解析後的路徑上，附件名稱沿用原始 basename。驗證：留言網址記在 Implementation Complete。
