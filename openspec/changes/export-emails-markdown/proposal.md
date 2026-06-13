## Why

大量信件歸檔目前必須**逐封用一個 LLM agent** 把 email body 機械式轉錄成 markdown 檔。這是整個歸檔流程的主成本，也是唯一會撞牆的環節：2026 一年 198 封的歸檔就因為 LLM 層（非 MCP 層）反覆觸發 Anthropic session / monthly spend 上限，resume 了 3 次才完成。2021–2025 的 backlog 是 **1,715 封**，用同樣的 per-email-LLM 方式估計約 30–50M tokens、會反覆撞牆。

關鍵：**瓶頸在 LLM 做 deterministic byte-copying，不在 MCP**。`che-apple-mail-mcp` 的 SQLite + `.emlx` fast path 在 2026 歸檔時穩穩供應了 187 封 body + 170 附件，毫無壓力。`get_email`→「寫 frontmatter + verbatim body 到 `.md`」這步**完全不需判斷**，卻因為「寫 markdown 檔」的能力在 client 端而被迫進 LLM 迴圈。

本 repo 其實**已備齊積木**：`MarkdownRendering.swift`（markdown 渲染）、`MailSQLite` fetch 層（`EnvelopeIndexReader` / `EmlxParser` / `EmailContent`）、`AttachmentExtractor`（v2.2.0 加的 `.emlx` 附件抽取 fast path）、以及 `batch-operations` published spec。缺的只是一個「批次 fetch → render → 寫檔」的 server-side tool，把 verbatim 轉錄徹底移出 LLM 路徑。

相關 issue：[#193](https://github.com/PsychQuant/che-apple-mail-mcp/issues/193)。

## What Changes

- **新增 MCP tool `export_emails_markdown`**（additive；不改任何既有 tool）。input：`ids[]` / `mailbox` / `account_name` / `output_dir` / `opts`。行為：批次 fetch 完整 body → 渲染 frontmatter + verbatim body 的 markdown → 寫 `output_dir`，回傳 manifest。
- **抽出 `MarkdownRendering` 的單封渲染函數** `renderEmailMarkdown(EmailContent, frontmatter fields) -> String`：frontmatter（見下）+ `Subject/From/To/Cc/Date` header + **verbatim body**（byte 級保真，不經任何改寫）。
- **frontmatter schema（published contract，凍結）**：`message_id` / `thread_key` / `in_reply_to` / `date`(ISO 8601 UTC) / `sender`(bare email) / `direction`(received|sent)。`opts.extra_frontmatter_fields` 可加選配欄位但不得移除這 6 個 core 欄位。沿用 `archive-mail` workflow 的既有慣例 → 既有歸檔零遷移。
- **`output_dir` 安全：allowed-roots 白名單**。新增 `AllowedRootsValidator`：canonicalize `output_dir`（解析 `..` 與 symlink）後，只允許落在使用者 home 或 config 設定的白名單根目錄之下；拒絕系統目錄（`/System`、`/usr`、`/bin`、`/etc` 等）與 symlink 逃逸。這是此 MCP **首次具備「寫任意 fs 路徑」的 surface**，故安全邊界先於彈性。
- **`opts.include_attachments`（bool）**：true 時，每封信的附件用既有 `AttachmentExtractor` 寫到 `output_dir/attachments/<stem>/`，data 類副檔名分流到 `output_dir/data/`（沿用既有 routing 慣例）。附件折進同一 tool（不另開 `save_attachments_bulk`），每封 md + 其附件原子處理。
- **檔名**：server 預設 `YYYY-MM-DD_<slug>.md`（date 取自信件 Date、slug 為 sanitized bare subject）+ 同名碰撞後綴 `-1`/`-2`；`opts.filename_template` 或 per-id override 可覆寫。manifest 一律回傳實際寫出的 path。
- **manifest 回傳**：per-id `{ message_id, written_path, attachments: [...], status: "written" | "error", error?: string }`。**partial-failure 不中斷**：單封 fetch/render/write 失敗記成該 id 的 error 條目並繼續，讓 caller 能據此續傳。
- **修改 `Server.swift`** 註冊新 tool + dispatch handler。
- **延伸 `openspec/specs/batch-operations/spec.md`**：新增「Server-side markdown export」requirement。
- **新增測試**：renderEmailMarkdown frontmatter/verbatim、allowed-roots validator（含 symlink 逃逸 / 系統目錄 / `..` 拒絕）、filename 碰撞後綴、partial-failure manifest、include_attachments 分流。
- **更新 `README` / `README_zh-TW` tool 清單 + `CHANGELOG`**。

## Non-Goals (optional)

- **Streaming / FileHandle pipeline**：沿用既有 in-memory 模式（同 `save_attachment` v2.2.0）。單一超大 part（>100 MB）沿用 `AttachmentExtractor` 既有的 `attachmentTooLarge` fall-through 行為，不在本 change rewrite 成 streaming。
- **caller 端去重 / 索引建構**：manifest 回 `message_id` 讓 caller 自建 dedup index（如 `email_index.json`）；本 tool 不寫索引、不做跨呼叫去重。
- **`cid:` inline image resolution / HTML 改寫**：與 `save_attachment` 同立場，超出 scope。
- **任意路徑寫檔（白名單外）**：被安全模型明確排除；要寫白名單外目錄需先改 config 白名單。
- **獨立 `save_attachments_bulk` tool**：附件已折進本 tool 的 `include_attachments`，不另開 tool。
- **skill 端優化（讓 `archive-mail` 改用既有 batch read tools）**：屬 `psychquant-claude-plugins` 的 archive-mail skill，不在本 repo scope（#193 residue）。

## Capabilities

### New Capabilities

(none — 不引入新 capability，而是在現有 `batch-operations` capability 下新增 server-side markdown export 這條 path)

### Modified Capabilities

- `batch-operations`：新增「Server-side markdown export」requirement — 規範 `export_emails_markdown` 的 input/output 契約、frontmatter schema（6 core 欄位）、allowed-roots 寫檔安全模型、檔名預設與覆寫、`include_attachments` 分流、partial-failure manifest 語義。

## Impact

**Affected code**:
- `Sources/CheAppleMailMCP/Server.swift` — 註冊 `export_emails_markdown` tool + dispatcher
- `Sources/CheAppleMailMCP/MarkdownRendering.swift` — 抽出 `renderEmailMarkdown` 單封渲染（frontmatter + header + verbatim body）
- `Sources/CheAppleMailMCP/AllowedRootsValidator.swift` — 新檔，output_dir canonicalize + 白名單 + symlink/系統目錄拒絕
- `Sources/MailSQLite/*`（`EnvelopeIndexReader` / `EmlxParser` / `EmailContent`）— 批次依 ids fetch 完整 body（重用既有 read path）
- `Sources/MailSQLite/AttachmentExtractor.swift` — `include_attachments` 時重用（不改既有 API）
- `Tests/...` — renderEmailMarkdown / AllowedRootsValidator / filename 碰撞 / partial-failure / attachment 分流
- `openspec/specs/batch-operations/spec.md` — 由 archive 自動更新（Spectra 處理）
- `README.md` / `README_zh-TW.md` / `CHANGELOG.md`

**Affected APIs**:
- 新增 MCP tool `export_emails_markdown`（additive，向後相容，不改任何既有 tool 的 input schema）
- `MarkdownRendering` 新增 public `renderEmailMarkdown`
- 新增 `AllowedRootsValidator` type

**Affected systems**:
- `archive-mail` skill 與任何 bulk 歸檔 caller：~200 封歸檔從 ~200 個 agent-invocation 降到 ≈1 次 server 呼叫；不再撞 API rate/session/spend 牆
- 個人本機使用者：得到大量歸檔能力，附件一併處理
- 測試數：新增約 8–12 個（render / validator / filename / partial-failure / attachment）
