## Why

直接寫入草稿（opt-in）在 `.emlx` 放好之後才失敗、在放檔途中失敗，或在 commit 之後被 `rollback(_:)` 還原時，會還原資料列、刪掉檔案，卻留下 `placeEmlx` 為這一列新建的 `Messages` 目錄（以及上層新建的雜湊目錄）。`direct-write-transaction-safety.md` 第 1 項要求「不留半套狀態」，而空目錄嚴格說就是留下的半套狀態（#503）。

## What Changes

- 放檔時逐層建立缺少的目錄，只記下這次呼叫自己建立成功的那幾層；原本就存在、或被別的程序先建好的層不算自己的。
- 寫入失敗（`insert` 在放檔之後失敗、放檔途中失敗）與 commit 之後的 `rollback(_:)`，在刪掉 `.emlx` 之後，以非遞迴、只刪空目錄的方式，由深到淺移除這次建立的目錄，遇到第一個不是空的就停。
- 清理不改變 `insert` 回報的錯誤，也不讓 `rollback(_:)` 因清理失敗而失敗。
- 加一個只給測試用的放檔掛點（正式執行時為 nil），讓測試能證明放檔已執行，並能在目錄建好之後讓放檔失敗。
- 規格：`message-composition` 的 Requirement: Direct-write draft path，寫入失敗與還原時一併移除這次建立、且仍為空的目錄。
- 規則檔 `.claude/rules/direct-write-transaction-safety.md` 第 1 項的覆蓋說明更新（原本的缺口與依賴空目錄的測試）。

## Non-Goals (optional)

- 不採用 Diagnosis 的選項 B（宣告空目錄無害、在規則第 1 項寫例外）：那會削弱一條封閉的保證。A 或 B 仍由維護者在 review 時決定。
- 不用 `FileManager.removeItem` 刪目錄：它對目錄是遞迴的，會刪掉 Mail 在這段時間寫進去的檔案。
- 不處理 `rollback(_:)` 不還原的資料列（`addresses`、`subjects`、`message_global_data`、`WriteTransactionGeneration`，#628）。
- 不改 `DirectDraftPath` 與它的凍結段；`attemptSteps` 與 `ensureRead` 不動。
- 不消除這個殘留競態：本次建立的空目錄在被移除前的瞬間，Mail 若剛好建立同一目錄並準備寫檔，移除可能早於 Mail 的寫檔。只發生在新的千位區塊第一列失敗時，記錄為已知限制。

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `message-composition`: Requirement: Direct-write draft path — 寫入失敗與還原時，一併移除這次為 `.emlx` 建立且仍為空的目錄。

## Impact

- Affected specs: `message-composition`
- Affected code:
  - `Sources/MailSQLite/DraftStoreWriter.swift`
  - `Tests/MailSQLiteTests/DraftStoreWriterDirectoryTests.swift`（新增）
  - `Tests/MailSQLiteTests/DraftStoreWriterTests.swift`
  - `.claude/rules/direct-write-transaction-safety.md`
