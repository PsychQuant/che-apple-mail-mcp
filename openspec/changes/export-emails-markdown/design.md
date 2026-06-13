## Context

`che-apple-mail-mcp` 自 v2.0.0 把讀取操作遷到 SQLite envelope index + 直接 `.emlx` 解析後，`get_email` / `list_attachments` / `get_emails_batch` / `save_attachment`（v2.2.0）都在毫秒級。但「把一批信轉成 markdown 檔」這件事目前**沒有 server-side 入口**，只能由 caller（LLM）逐封 `get_email` 後自己拼 frontmatter + body 寫檔。

實證（2026 Peng gAB 歸檔）：MCP/SQLite 層穩供 187 封 body + 170 附件無壓力，但「逐封 LLM 轉錄」反覆撞 Anthropic session / monthly spend 上限、resume 3 次。2021–2025 backlog 1,715 封以同法估 30–50M tokens。轉錄是 deterministic byte-copy，不該佔 LLM。

積木已備齊：`MarkdownRendering`（渲染）、`MailSQLite` read path、`AttachmentExtractor`（`.emlx` 附件 fast path）、`batch-operations` spec。本 change 把它們組裝成一個 server-side tool。

### Stakeholders
- `archive-mail` skill / bulk 歸檔 caller — 主要受益者（~200 封 → ≈1 呼叫）
- 個人本機使用者 — 取得大量歸檔 + 附件能力
- 既有測試 — 不可 regression（additive only）

## Goals / Non-Goals

**Goals:**
1. 提供 `export_emails_markdown` 一個 server-side tool，批次 fetch + render + 寫檔，把 verbatim 轉錄移出 LLM 路徑。
2. frontmatter 作為穩定 published contract（沿用 archive-mail 既有 6 欄）。
3. 寫檔安全：allowed-roots 白名單，杜絕 path traversal / 任意覆寫。
4. 選配附件，與 md 原子處理；重用既有 `AttachmentExtractor`，不改其 API。
5. partial-failure 不中斷、逐封回報，支援 caller 續傳。
6. 零既有 API breakage（additive tool；不改既有 tool input schema / `parseBody` / `ParsedEmailContent`）。

**Non-Goals:**
1. Streaming pipeline（沿用 in-memory；>100 MB part 沿用 `attachmentTooLarge` fall-through）。
2. caller 端去重 / 索引（manifest 回 message_id，caller 自建）。
3. `cid:` inline image resolution。
4. 白名單外任意路徑寫檔。
5. 獨立 `save_attachments_bulk`（折進 `include_attachments`）。

## Decisions

### D1. 單一 tool `export_emails_markdown`（不拆 read/write）
**選**：一個 tool 做完 fetch + render + write，回 manifest。
**捨**：(a) 拆 `get_emails_batch`(read) + 新 write tool；(b) 只擴 `get_emails_batch` 回完整 body、寫檔仍 caller 做。
**理由**：#193 初衷是「一呼叫完成大量歸檔、LLM 不進轉錄迴圈」。拆 read/write 仍要 caller 串兩步且自己寫檔（LLM 仍在迴圈）；只擴 batch read 只達成一半。單一 tool 最貼初衷。read/write 各自重用既有 building blocks，內聚度足夠，不需為「模組化」拆開。

### D2. `output_dir` 安全 = allowed-roots 白名單
**選**：canonicalize（解析 `..` 與 symlink 到 real path）後，要求 real path 落在 {使用者 home} ∪ {config `export_allowed_roots` 白名單} 之下；否則 reject。額外硬性拒絕寫入系統目錄（`/System`、`/usr`、`/bin`、`/sbin`、`/etc`、`/private/etc`、`/Library`（非 `~/Library`）等）。
**捨**：(a) 任意絕對路徑（只 canonicalize + 拒系統目錄）；(b) 嚴格單一 sandbox 根。
**理由**：這是此 MCP 史上**第一個寫任意 fs 路徑**的 surface，一旦發布難收回。即使是本機個人工具、無不信任 caller，prompt-injection 讓 LLM 帶出惡意 `output_dir`（例如覆寫 `~/.ssh/authorized_keys` 或 launch agent）的風險不對稱。白名單在「夠用的彈性」與「安全預設」間取得平衡：home 底下涵蓋絕大多數歸檔場景，跨專案歸檔可在 config 加根。嚴格單 sandbox 太死（跨 repo 歸檔會綁手）。
**演算法**（pseudocode）：
```
canon = realpath(output_dir)                 # resolves .. and symlinks
if not exists(canon): canon = realpath(nearest existing ancestor) + remaining
roots = [realpath(home)] + [realpath(r) for r in config.export_allowed_roots]
if not any(canon == r or canon.hasPrefix(r + "/") for r in roots): REJECT
if canon matches SYSTEM_DENYLIST_PREFIX: REJECT       # belt-and-suspenders
```
symlink 逃逸由 realpath 在比對前解析根除（canon 是 real path，白名單根也 realpath 過）。

### D3. frontmatter schema = 凍結 6 欄 + 選配
**選**：core 6 欄固定：`message_id` / `thread_key` / `in_reply_to` / `date`(ISO 8601 UTC) / `sender`(bare) / `direction`。`opts.extra_frontmatter_fields` 只能加、不能移除 core。
**理由**：這已是 archive-mail workflow 寫出的 de-facto 格式，沿用 → 既有歸檔零遷移、跨工具一致。frozen contract 必須 minimal-but-complete：這 6 欄足以支撐 dedup（message_id）、thread 聚合（thread_key/in_reply_to）、排序（date）、收發判定（direction）。

### D4. 檔名 policy：server 預設 + caller 可覆寫
**選**：server 預設 `YYYY-MM-DD_<slug>.md`（date 取信件 Date header；slug 為 bare subject sanitize：標點轉 `-`、保留 CJK、截 ~50 grapheme）+ 同 (date, bare-subject) 群組內碰撞後綴 `-1`/`-2`。`opts.filename_template`（支援 `{date}`/`{subject}`/`{sender}`/`{message_id}` 佔位）或 per-id `filenames` map 可覆寫。manifest 一律回實際 path。
**理由**：時區與 slug 政策不該硬烤進 MCP（caller 可能要 Taiwan date、不同截斷），但要開箱即用。回傳實際 path 讓 caller 能 rename / 建索引。碰撞後綴在 server 端做（同批內可見全部 id，可 race-free 指派）。

### D5. 附件折進同一 tool
**選**：`opts.include_attachments=true` 時，每封信用既有 `AttachmentExtractor.saveAttachment` 把附件寫到 `output_dir/attachments/<stem>/`（document 類）與 `output_dir/data/`（data 類副檔名），md 末尾加 `Attachments:` 區塊。
**理由**：附件與其信件原子處理（同一批、同一安全邊界）；重用 v2.2.0 既有 `.emlx` 附件 fast path，不另開 tool、不改其 API。data/document 分流沿用 archive-mail 既有慣例。

### D6. partial-failure：manifest 逐封回報、不中斷
**選**：對每個 id 包 per-email try/catch；失敗記 `{message_id?, status:"error", error}` 並繼續；成功記 `{message_id, written_path, attachments[], status:"written"}`。
**理由**：1,715 封的批次裡單封壞信（malformed MIME、超大 part、缺 .emlx）不該讓整批失敗。caller 依 manifest 的 error 條目續傳即可。對齊既有 `get_emails_batch` 的 BatchValidator / partial 結果精神。

### D7. 重用既有 read path，不新增 SQLite schema
fetch body 走 `EnvelopeIndexReader` + `EmlxParser`（同 `get_email`），不做任何 DDL；附件走 `AttachmentExtractor`（同 `save_attachment`）。本 tool 是這兩條既有 fast path 的批次組合 + 寫檔層。
