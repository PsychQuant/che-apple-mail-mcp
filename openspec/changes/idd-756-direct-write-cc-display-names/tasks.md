## 1. 測試（先寫，先看到失敗）

- [ ] 1.1 `DirectDraftPathTests`：組信。標頭含 `To: "Doe, Jane" <jane@example.test>` 且在最後，`Cc:` 在 `Date:` 之後，內容是 `a@example.test` 加上 `陳小明` 的編碼字串與 `<b@example.test>`。標記 `spec-example: message-composition / one named To and two Cc`。
- [ ] 1.2 `DraftStoreWriterTests`：同一份輸入寫進合成的 store 後，`recipients` 是 `(0,0)`、`(1,1)`、`(1,2)`，`addresses` 的 comment 依序是 `Doe, Jane`、`''`、`陳小明`。標記同 1.1。
- [ ] 1.3 `DirectDraftPathTests`：12 個帶非 ASCII 名字的 Cc，折疊後每行都在長度上限內，續行以空白開頭，沒有編碼字串或引號字串被切開。標記 `spec-example: message-composition / a long Cc list folds between mailboxes only`。
- [ ] 1.4 `DirectDraftPathTests`：名字含換行的 Cc 判為資格不符（display-name 理由），store 不被打開。標記 `spec-example: message-composition / a name with a newline goes to the GUI path`。
- [ ] 1.5 `DraftStoreWriterTests`：預先有 `(a@example.test, '')` 被另一封信使用；寫入新增 `(a@example.test, 'Anna')` 並重用 `(a@example.test, '')`；還原後前者消失、後者仍在。標記 `spec-example: message-composition / reversal deletes the new name row and keeps the old one`。
- [ ] 1.6 把既有的 cc/bcc 不符條件測試拆成兩條：Bcc 維持「store 沒被動、沒有觸發」，理由文字改為 `bcc is not written directly`；Cc 改由 1.1、1.2 涵蓋正向行為。

## 2. 實作

- [ ] 2.1 `DirectDraft.eligibility`：第 3 項只看 `bcc`；To 與 Cc 的每個條目都過地址檢查，名字含 CR、LF、NUL 判為 display-name 理由；新增 `Ineligible.bcc`（訊息 `bcc is not written directly`）。
- [ ] 2.2 `DirectDraft.buildMessage`：改收一份依序的收件人清單；`Cc:` 放在 `Date:` 之後；每個信箱用 `formatMailbox`；新增 `foldedMailboxList`，只在信箱之間斷行。
- [ ] 2.3 `DraftStoreWriter.Draft` 與 `insert`：收件人清單取代 `toAddresses`；`addresses` 以 (address, comment) 查找或新建，記下新建的 ROWID；`recipients` 寫入 type 與跨 type 的 position。
- [ ] 2.4 `DraftStoreWriter.rollback`：在同一個交易裡，刪掉記下的、沒有被 `recipients.address`、`messages.sender`，以及表存在時的 `sender_addresses.address`、`business_addresses.address` 引用的 `addresses` 列。
- [ ] 2.5 `DirectDraftPath`：在 `timer.mark("inserted")` 之前把 To、Cc 與名字組成清單交給 `Draft`；凍結段與 `ensureRead` 不動，仍只有一處 `writer.insert(`。

## 3. 文件與驗證

- [ ] 3.1 README（兩份）的直接寫入一節：可以帶 Cc 與顯示名稱；Bcc、空主旨、沒給 `from_address` 仍走 GUI 路徑。CHANGELOG 的 [Unreleased] 加一條。
- [ ] 3.2 全套測試、`DirectWriteSafetyGuardTests` 維持綠燈、本機 CI 閘門。
- [ ] 3.3 跨模型驗證（Codex；額度 2026-11-27 08:43 +08:00 恢復）。

## 4. Live 檢查（需要維護者說「測」，只用維護者自己的 IMAP 帳號與地址）

- [ ] 4.1 依查證 comment 7082362852 的案例與量測：每種情況各做一封直接寫入、一封同一天同輸入的 GUI 路徑草稿，比對資料列、comment、標頭欄位名；Mail 讀出的收件人等於輸入；同步與重開 Mail 後仍只有一份；伺服器上的副本看得到 Cc；含一次刻意讓觸發失敗的還原。結果只記數字與標頭欄位名。
