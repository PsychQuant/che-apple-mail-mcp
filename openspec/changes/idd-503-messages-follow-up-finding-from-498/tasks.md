## 1. 測試先行（每個 Example 一個測試，先看到失敗）

測試檔 `Tests/MailSQLiteTests/DraftStoreWriterDirectoryTests.swift`，用合成的 store（不需 Full Disk Access），每個測試帶 `spec-example: message-composition / <Example title>` 標記。

- [x] 1.1 Direct-write draft path：寫入在放檔之後失敗時，新建的 `Data/0`、`Data/0/2`、`Data/0/2/Messages` 都被移除，`Data` 保留，錯誤仍是 `no WriteTransactionGeneration`。驗證：`testANewHashBlockIsRemovedAfterALaterStepFails`（spec-example: message-composition / a new hash block is removed after a later step fails）
- [x] 1.2 Direct-write draft path：放檔途中（目錄建好、檔案還沒寫）失敗時，新建的目錄被移除、`Data` 保留。驗證：`testAFailureWhilePlacingTheFileRemovesTheNewDirectories`（spec-example: message-composition / a failure while placing the file removes the new directories）
- [x] 1.3 Direct-write draft path：新建的 `Messages` 目錄裡多了別的檔案時，寫入失敗只刪自己放的 `20000.emlx`，別的檔案與它的目錄都保留。驗證：`testAnotherFileInTheNewMessagesDirectorySurvivesAFailedWrite`（spec-example: message-composition / another file in the new Messages directory survives a failed write）
- [x] 1.4 Direct-write draft path：commit 之後還原時，新建目錄裡多了別的檔案，還原不丟錯、只刪自己的檔案，目錄保留。驗證：`testAnotherFileInTheNewMessagesDirectorySurvivesAReversal`（spec-example: message-composition / another file in the new Messages directory survives a reversal）
- [x] 1.5 Direct-write draft path：`Data/0` 原本就存在時，還原只移除這次建立的 `Data/0/2` 與 `Data/0/2/Messages`，`Data/0` 保留。驗證：`testReversalRemovesOnlyTheLevelsTheWriteCreated`（spec-example: message-composition / reversal removes only the levels the write created）
- [x] 1.6 Direct-write draft path：目標路徑已有 `20000.emlx` 時寫入失敗，不寫任何資料列，那個檔案的內容與目錄都不變。驗證：`testAnExisting20000EmlxIsLeftAsItWas`（spec-example: message-composition / an existing 20000.emlx is left as it was）

## 2. 實作（`Sources/MailSQLite/DraftStoreWriter.swift`）

- [x] 2.1 放檔時逐層 `mkdir(2)`，只記下這次 `mkdir` 成功建立的層（`EEXIST` 且是目錄的層不記），清單放在 `Inserted.createdDirectories`；`Inserted` 的初始化保留舊的六個參數（新欄位預設空陣列），既有測試照常編譯。驗證：1.1、1.5 轉綠，`swift build` 通過。
- [x] 2.2 `insert` 失敗（放檔之後、或放檔途中）時，在刪掉 `.emlx` 之後以 `rmdir(2)` 由深到淺移除這次建立的目錄，遇到第一個移除不了的就停（`ENOENT` 例外，繼續往上）；拋出的錯誤不變。驗證：1.1、1.2、1.3、1.6 轉綠，既有的 `testInsertLeavesNothingBehindWhenTheFileCannotBeWritten` 仍綠。
- [x] 2.3 `rollback(_:)` 在 commit 刪除資料列並刪掉 `.emlx` 之後，同樣移除 `createdDirectories`；移除失敗不讓 `rollback` 丟錯，非 `ENOTEMPTY`／`ENOENT` 的失敗寫到 stderr。驗證：1.4、1.5 轉綠，`DraftStoreWriterReadFailureTests` 仍綠。
- [x] 2.4 加一個只給測試用的放檔掛點（internal、預設 nil）：目錄建好後、檔案放好後各呼叫一次，掛點丟錯時照放檔失敗處理。驗證：1.2 能讓放檔在目錄建好後失敗；正式程式沒有任何地方設定它（`grep -n placementHook Sources/` 只有宣告與兩個呼叫點）。

## 3. 既有測試與規則

- [x] 3.1 `testInsertRemovesThePlacedFileWhenALaterStepFails` 改用放檔掛點證明放檔已執行（掛點在檔案放好時看到檔案存在），並改為斷言新建的目錄已被移除。驗證：該測試綠；拿掉 ROLLBACK、拿掉刪檔、把失敗移到放檔之前、拿掉目錄清理這四個 mutation 各自讓它或 1.x 測試轉紅。
- [x] 3.2 `.claude/rules/direct-write-transaction-safety.md` 第 1 項的覆蓋說明：移除「失敗後會留下空的 `Messages` 目錄（#503）」的缺口與「測試靠這個目錄證明放檔已執行」的敘述，改寫為目錄清理與新測試的覆蓋。驗證：內容審閱，`DirectWriteSafetyGuardTests` 仍綠。
- [ ] 3.3 全部測試：`swift test` 的 MailSQLite 與 CheAppleMailMCP 兩個 bundle 都 0 failures。驗證：分別讀兩個 bundle 的 `Executed N tests` 行。
