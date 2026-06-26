## Context

`export_emails_markdown` 已能 binary-side 寫 markdown（frontmatter + 檔名規則）並回 manifest（`{written, errors, items:[{id, status, writtenPath, attachments}]}`），且**零內容進 LLM context**；`search_emails projection: ids`（既有 `projection` enum：`full` / `ids` / `count`）已能產生餵給它的小 id 清單。本變更補強這些既有 surface，讓 `search → export` composition 成為完整、**dedup-aware**、O(1)-context 的歸檔原語——不需新 tool，binary 也不擁有任何歸檔索引格式。下游 `email_index.json` / `threads.json` 索引維持是呼叫端的 contract。

## Goals / Non-Goals

**Goals**
- 重跑歸檔只寫**新**信（dedup），由呼叫端提供的「已歸檔 Message-ID 集合」驅動——且該集合本身不進 context。
- 呼叫端能只靠（很小的）export manifest 維護 Message-ID-keyed 索引，不用重抓內容。
- 一個介於 `ids`（太稀疏）與 `full`（O(corpus)）之間的 triage projection。
- `get_emails_batch` 與單封 `get_email` 達成 Message-ID 對齊。

**Non-Goals**
- 不做 `archive_emails` tool；binary 永不讀／寫／定義歸檔索引。
- `get_emails_batch` 不加 `output_path`（延後）；不改 markdown／frontmatter／檔名格式。

## Decisions

### D1
**dedup 輸入是檔案路徑，不是 inline Message-ID 陣列。** `export_emails_markdown` 新增 `skip_message_ids_path`（optional）：指向一個列出「已歸檔 RFC 5322 Message-ID」的檔案（一行一個；空行與開頭為 `#` 的註解行忽略）。binary 讀它，對每個候選 id，若其解析出的 `Message-ID` 在集合內，就**跳過**寫檔。

- *為何用路徑而非 inline 陣列*：上千個 Message-ID 的 inline 陣列本身會流經 context，違背 O(1) 目標；路徑把 dedup 集合留在磁碟。
- *安全*：路徑為**唯讀**，套用與 `output_dir` **相同的 allowed-roots policy**（重用 `AllowedRootsValidator`）；檔案只當 Message-ID 行清單 parse、回應永不回吐其內容，所以惡意路徑只會得到不命中的行、不會洩漏。缺檔／不可讀 → 視為空集合（不跳過）+ stderr note，**非**硬錯誤（首次歸檔還沒有索引）。
- *比對*：對完整 `Message-ID` 字串（含可能的角括號）做精確、case-sensitive 比對，與 `get_email` / manifest emit 的形式一致。

### D2
**manifest 補 `message_id`；skipped item 為一級公民。** 每個 `ExportManifestItem` 補 `message_id: String`（解析出的 RFC 5322 Message-ID；來源無則空字串，沿用 #198 `in_reply_to` 慣例）。被跳過的候選以 `status: "skipped"` 的 item 出現（含其 `message_id`），manifest summary 在 `written` / `errors` 之外新增 `skipped` 計數。呼叫端因此能只靠 manifest 對帳自己的索引。

### D3
**`summary` projection 形狀。** `search_emails` 的 `projection` enum 新增 `summary`。它回與 `full`/`ids` **相同的 envelope**（`{results, returned, limit, truncated}`），但 `results` 每個元素剛好是 `{id, date, sender, subject, mailbox}`——`date` 用與 reader `date_received` 相同的 ISO 8601 格式。與 `ids`/`count` 一樣**僅 SQLite**（需 Envelope Index；AppleScript fallback 拒非 `full` projection，維持不變）。不含 `to`/`cc`/重複 account 欄位（即 issue 量到的 triage 成本）。**與 `dedup: logical` 相容**（不像 `full`），因為 `summary` 不做 recipient 子查詢、可用 `GROUP BY` + `MIN(ROWID)` 取代表列。

### D4
**`get_emails_batch` 補 `message_id`。** 每個 per-email result object 補 `message_id`（取自 `EmailContent.messageId`；無則空字串），與單封 `get_email` 對齊。純加欄位、無移除。

## Risks / Trade-offs

- **skip-set 過期**：呼叫端傳的是已歸檔 Message-ID 的快照；另一個並行 run 同時歸檔的信不會被 dedup。可接受——歸檔實務上非並行，且重複寫是**幂等**（相同檔名規則）而非破壞。
- **`skip_message_ids_path` 讀取面**：以 allowed-roots 驗證 + 只當 Message-ID parse + 不回吐內容緩解。
- **projection 詞彙漂移**：`summary` 必須與 `ids`/`count`/`full` 及 `dedup` 參數（#208）乾淨並存；spec 釘住 enum，避免未來值碎片化。

## Migration / Compatibility

四項皆**加法**：一個新 optional `export_emails_markdown` 參數 + 一個新 manifest 欄位 + 一個新 `skipped` 計數；一個新 `projection` enum 值；一個新 `get_emails_batch` result 欄位。既有呼叫端（無 `skip_message_ids_path`、`projection: full`/`ids`/`count`、忽略未知欄位）不受影響。
