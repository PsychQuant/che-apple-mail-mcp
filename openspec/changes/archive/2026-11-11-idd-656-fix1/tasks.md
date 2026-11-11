## 1. 測試

- [x] 1.1 List VIP senders via filesystem：mail storage path 被 override 到測試目錄、reader 沒有注入路徑時，列出那個目錄 `MailData/VIPMailboxes.plist` 裡的一筆。驗證：`FilesystemQueryTests.testTheDefaultFollowsTheMailStorageOverride`（spec-example: sqlite-query-engine / the default follows the test override of the mail storage path）；把 nil 分支改讀別處的 mutation 讓它轉紅。
- [x] 1.2 List VIP senders via filesystem：`HandlerVIPListTests` 裝上會丟錯的 script seam，斷言沒有 script 跑過、回傳恰好那一筆（spec-example: sqlite-query-engine / list_vip_senders answers from the server's VIP list path）。驗證：該測試綠。

## 2. 文件

- [x] 2.1 `CHANGELOG.md` 的 #656 條目：預設跟著 override、開成的 reader 不讀使用者清單、reader 沒開成時的 AppleScript 退回不變。驗證：內容審閱。
- [x] 2.2 全部測試：兩個 bundle 都 0 failures。驗證：分別讀兩個 bundle 的 `Executed N tests` 行。
