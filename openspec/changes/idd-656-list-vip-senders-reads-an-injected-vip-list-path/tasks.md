## 1. 測試先行

- [x] 1.1 List VIP senders via filesystem：用注入路徑建立的 reader 列出那個 plist 的一筆，路徑上沒有檔案時列出空清單。驗證：`FilesystemQueryTests.testAnInjectedVIPListIsTheOneListed`（spec-example: sqlite-query-engine / an injected VIP list is the one listed），不需真的 index。
- [x] 1.2 List VIP senders via filesystem：用注入路徑建立的伺服器，`list_vip_senders` 回傳恰好那一筆。驗證：`HandlerVIPListTests.testListVipSendersAnswersFromTheServersVIPListPath`（spec-example: sqlite-query-engine / list_vip_senders answers from the server's VIP list path）。
- [x] 1.3 List VIP senders via filesystem：沒有注入、沒有 override 時，預設路徑是 `<home>/Library/Mail/V10/MailData/VIPMailboxes.plist`。驗證：`FilesystemQueryTests.testWithoutAnInjectedPathTheUsersVIPListIsRead`（spec-example: sqlite-query-engine / without an injected path the user's VIP list is read）。

## 2. 實作與文件

- [x] 2.1 `EnvelopeIndexReader` 加 `vipMailboxesPath` 與 `defaultVIPMailboxesPath`；伺服器 `init` 加同名參數並傳給 reader。驗證：1.1–1.3 綠，其他 reader 與 handler 測試仍綠。
- [x] 2.2 `CHANGELOG.md` 條目。驗證：內容審閱。
- [ ] 2.3 全部測試：兩個 bundle 都 0 failures。驗證：分別讀兩個 bundle 的 `Executed N tests` 行。
