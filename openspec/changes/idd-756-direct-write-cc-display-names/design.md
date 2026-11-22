## Context

直接寫入在一個 `BEGIN IMMEDIATE` 交易內寫進 Envelope Index 與 `.emlx`，再切換已讀狀態讓 Mail 上傳。現在只寫 To：
- `buildMessage` 只產生 `To:` 標頭；
- `DraftStoreWriter.insert` 把每個收件人寫成 type 0，`addresses.comment` 固定是 `''`。

這次的證據（維護者自己的 store，只讀統計數字與標頭欄位名）：
- `recipients.type` 全庫只有 0 與 1。
- 16,708 封有 Cc 的信，最小的 Cc position 都等於 To 的數量。
- Mail 存的 3 封有 Cc 的草稿，`Cc:` 都在 `Date:` 之後，`To:` 在最後。
- `addresses` 有 `UNIQUE(address, comment)`；comment 存解碼後、不加引號的名字（8,566 筆非 ASCII、183 筆含逗號，都沒有加引號）。
- 地址保留原大小寫。
- `recipients`、`addresses`、`subjects` 都沒有 trigger。

## Goals / Non-Goals

**Goals：**
- Cc 與 To／Cc 的顯示名稱走直接寫入，結果和 Mail 自己存的草稿一致；
- 還原時清掉這次新建的 `addresses` 列。

**Non-Goals：** Bcc、空主旨、預設寄件帳號（理由見 proposal）。

## Decisions

### 一份收件人清單同時產生標頭與資料列

`Draft` 改成帶一份 `[(address, name?, kind)]`，To 在前、Cc 在後。`buildMessage` 與 `insert` 都從這份清單推導，標頭順序和資料列的 position 不可能各寫各的。另一種做法是 To、Cc 兩個參數各傳一份，但那樣 position 要在兩處各自計算，容易對不上。

### 名字用既有的 `formatMailbox`，折疊另寫一個

`formatMailbox` 已經在產生 `From:`，和 Mail 的兩種寫法一致：非 ASCII 用 RFC 2047 編碼，含特殊字元的 ASCII 名字加引號。`foldedHeaderLine` 在任何空白處斷行，`subjectHeader` 的註解寫明它不能碰編碼字串，所以另寫 `foldedMailboxList`：只在 `, ` 之後斷行；單一信箱就太長時，在名字與 `<addr>` 之間斷行。

### CR、LF、NUL 在資格檢查就拒絕

名字裡的換行會讓標頭提早結束，等於注入一個新標頭（例如偽造 `Bcc:`）。這屬於輸入不合格，不是格式問題，所以放在資格清單第 5 項。清單仍是 10 項：第 3 項（只剩 Bcc）、第 5 項（名字含控制字元）、第 6 項（地址檢查擴大到 Cc）都是就地改寫，所以 `direct-write-transaction-safety.md` 裡「10 項適用條件」的數字不用改。

### 還原清掉這次新建的 `addresses` 列

`insert` 在每次 `INSERT OR IGNORE INTO addresses` 之後看 `sqlite3_changes()`，等於 1 就記下這列的 ROWID，放進 `Inserted`。`rollback()` 在它自己的交易裡，刪掉其中沒有被任何東西引用的列：`recipients.address`、`messages.sender`，以及表存在時的 `sender_addresses.address`、`business_addresses.address`（這兩張由 Mail 自己填，store 裡分別有 2,202、20,420 列；只查前兩張的話，可能刪到 Mail 已經拿去用的列）。`subjects` 與更早的殘留不動，留給 #628。交易失敗時，原本的 `ROLLBACK` 本來就會撤掉這些列。

## Risks / Trade-offs

- [風險] 刪掉 Mail 剛好在同一瞬間也開始使用的地址列。→ 緩解：引用檢查與刪除在同一個 `BEGIN IMMEDIATE` 交易內完成，Mail 在這段期間拿不到寫入鎖。
- [風險] 標頭順序或折疊和 Mail 不同，導致 Mail 第一次打開時重寫草稿。→ 緩解：live 檢查時拿同一天、同樣輸入的 GUI 路徑草稿逐欄比對。
- [取捨] 地址照輸入的大小寫存。`addresses.address` 是 `COLLATE NOCASE`，大小寫不同的同一個地址會重用既有的列，不會新建，這和 Mail 的行為一致。

## Migration Plan

沒有資料遷移。行為只在 opt-in 開啟時改變；關閉時 `create_draft` 完全不變。

## Open Questions

（無。Bcc 與空主旨已在 Decision comment 7082383020 定案為不在這一步。）
