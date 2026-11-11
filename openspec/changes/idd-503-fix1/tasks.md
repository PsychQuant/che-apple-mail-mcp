## 1. 測試先行

- [x] 1.1 Direct-write draft path：還原時最深的 `Messages` 已被別的程序移除，清理略過它、繼續移除 `Data/0/2` 與 `Data/0`，`Data` 保留，還原成功。驗證：`testAVanishedMessagesDirectoryDoesNotStopTheCleanup`（spec-example: message-composition / a vanished Messages directory does not stop the cleanup）；把 `ENOENT` 改成停下的 mutation 必須讓它轉紅。
- [x] 1.2 Direct-write draft path：`Data/0/2` 設成唯讀、`Messages` 移除不了時，還原成功、`20000.emlx` 被移除、三層目錄都保留，stderr 有一行含 `could not remove created directory` 與 `Messages` 的路徑。驗證：`testAPermissionFailureOnMessagesIsNotedOnStderr`（spec-example: message-composition / a permission failure on Messages is noted on stderr）；拿掉 stderr 那一行的 mutation 必須讓它轉紅。

## 2. 文字與既有測試

- [x] 2.1 `testInsertRemovesThePlacedFileWhenALaterStepFails` 斷言這次建立的最淺層目錄也已不存在，讓它的 doc comment 與規則第 99 行的說法成立。驗證：該測試綠；只移除最深一層的 mutation 讓它轉紅。
- [x] 2.2 `.claude/rules/direct-write-transaction-safety.md` 第 1 項：停止條件寫成「略過已不存在的、停在第一個仍存在卻移除不了的」，競態前提改成「這次寫入是該 Drafts mailbox 在這個千位區塊的第一列（Drafts 訊息少時很常見）」，競態描述改成 Mail 找到這次建立的目錄、還沒寫檔。驗證：內容審閱。
- [x] 2.3 `CHANGELOG.md` #503 條目：目錄建立失敗時 `emlxWrite` 的文字改變且帶目錄路徑、`ENOENT` 會被略過不寫 stderr、「never removed」改成只講建立當下、補上殘留競態與它的前提。驗證：內容審閱。
- [ ] 2.4 全部測試：`swift test` 兩個 bundle 都 0 failures。驗證：分別讀兩個 bundle 的 `Executed N tests` 行。
