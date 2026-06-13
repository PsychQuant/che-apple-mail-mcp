## 1. AllowedRootsValidator（output_dir 安全，D2）

- [ ] [P] 1.1 新檔 `Sources/CheAppleMailMCP/AllowedRootsValidator.swift`：`public struct AllowedRootsValidator`，`validate(_ outputDir: String, allowedRoots: [String]) throws -> URL`（回 canonical URL）。流程：realpath 解析（含不存在路徑時取最近存在 ancestor + 剩餘段）→ 比對 home ∪ config 白名單根 → 系統目錄 denylist belt-and-suspenders。
- [ ] [P] 1.2 typed errors：`outputDirEscapesAllowedRoots(path:)` / `outputDirIsSystemPath(path:)`，dispatcher 可區分回報。
- [ ] [P] 1.3 `Tests/.../AllowedRootsValidatorTests.swift`：home 下接受、白名單根下接受、`..` 逃逸拒絕、symlink 指向系統目錄拒絕、`/etc` 等系統目錄拒絕、不存在但合法的巢狀路徑接受（會 mkdir）。
- [ ] 1.4 config 讀取 `export_allowed_roots`（沿用既有 config 載入機制；未設時白名單 = [home]）。

## 2. renderEmailMarkdown（單封渲染，D3）

- [ ] 2.1 在 `Sources/CheAppleMailMCP/MarkdownRendering.swift` 新增 public `renderEmailMarkdown(_ email: EmailContent, extraFields: [String]) -> String`：YAML frontmatter（core 6 欄 `message_id`/`thread_key`/`in_reply_to`/`date` ISO UTC/`sender` bare/`direction`）+ 空行 + `Subject/From/To/Cc/Date` header（cc 為空則省略該行）+ 空行 + **verbatim body**。
- [ ] 2.2 `thread_key` 計算：strip 前綴 `Re:/RE:/Fwd:/FW:/转发:/轉寄:/回覆:/回复:`（重複移除）後 trim。`direction`：寄件匣/Sent 或 sender==帳號 → sent，否則 received。
- [ ] 2.3 `message_id` 用雙引號包（避免 YAML 解析角括號）；frontmatter 值含雙引號時轉單引號。
- [ ] [P] 2.4 `Tests/.../MarkdownRenderingTests.swift`：6 欄齊全、cc 省略、verbatim body 不被改寫（含引用層 + 簽名逐字）、extraFields 附加、Re: 前綴剝除。

## 3. 檔名 policy（D4）

- [ ] 3.1 預設 template `YYYY-MM-DD_<slug>.md`：date 取信件 Date header；slug = bare subject sanitize（標點/空白轉 `-`、保留 CJK/Unicode、截 ≤50 grapheme、去頭尾 `-`、空則 `no-subject`）。
- [ ] 3.2 同批內 (date, bare-subject) 群組碰撞後綴：群組內依日期序，第 1 封無後綴、其餘 `-1`/`-2`…（server 端可見全批 → race-free）。
- [ ] 3.3 `opts.filename_template`（佔位 `{date}`/`{subject}`/`{sender}`/`{message_id}`）與 per-id `filenames` map 覆寫；覆寫時仍做檔名安全字元 sanitize。
- [ ] [P] 3.4 測試：預設命名、CJK subject slug、同日同主旨碰撞後綴、template 覆寫、per-id 覆寫。

## 4. export_emails_markdown 核心（批次 + manifest，D1/D6/D7）

- [ ] 4.1 批次依 `ids[]` 用 `EnvelopeIndexReader` + `EmlxParser` fetch 完整 body（重用既有 read path，不新增 SQLite schema）。
- [ ] 4.2 對每封：render（§2）→ 決定檔名（§3）→ `Data.write(to: output_dir/filename)`（output_dir 已過 §1 validator + mkdir -p）。
- [ ] 4.3 **partial-failure**：per-email try/catch；失敗記 `{message_id?, status:"error", error}` 續跑；成功記 `{message_id, written_path, attachments[], status:"written"}`。
- [ ] 4.4 回傳 manifest（JSON）：`{ output_dir, written: N, errors: M, items: [per-id ...] }`。
- [ ] 4.5 測試：多封全成功、混入一封 malformed（manifest 有 error 條目且其餘照寫）、空 ids、output_dir 被 validator 拒（整批 fail-fast，不寫任何檔）。

## 5. include_attachments 整合（D5）

- [ ] 5.1 `opts.include_attachments=true` 時，對每封信用既有 `AttachmentExtractor.saveAttachment` 寫附件到 `output_dir/attachments/<stem>/`（document）與 `output_dir/data/`（data 類副檔名：csv/tsv/sav/dta/parquet/feather/xlsx/sas7bdat/rds）。stem = 檔名去 `.md`。
- [ ] 5.2 md 末尾加 `Attachments:` 區塊（相對連結 + 大小）；附件路徑寫入該 id 的 manifest `attachments[]`。
- [ ] 5.3 附件抽取失敗不中斷該封 md（附件失敗記在 manifest 該 id 的 attachment 子條目）。
- [ ] [P] 5.4 測試：含附件信分流正確（data vs document）、無附件信略過、附件抽取失敗的 manifest 記錄。

## 6. Server.swift tool 註冊 + dispatcher

- [ ] 6.1 在 `Sources/CheAppleMailMCP/Server.swift` 註冊 `export_emails_markdown` tool（input schema：`ids` array / `mailbox` / `account_name` / `output_dir` / `opts` object：`include_attachments`/`filename_template`/`filenames`/`extra_frontmatter_fields`）。
- [ ] 6.2 dispatcher：parse args → AllowedRootsValidator → 核心（§4）→ 回 manifest JSON。account_name 沿用既有 display-name 解析（避免 -1728 類問題）。
- [ ] 6.3 README.md / README_zh-TW.md tool 清單新增條目；CHANGELOG.md 新版本 entry。

## 7. Spec + build verify

- [ ] 7.1 `openspec/specs/batch-operations/spec.md` 由 change 的 spec delta（`specs/batch-operations/spec.md`）於 archive 時併入（Spectra 處理）。
- [ ] 7.2 `swift build` 通過、`swift test` 全綠（既有測試零 regression + 新增測試通過）。
- [ ] 7.3 `spectra validate --change export-emails-markdown` 通過。
- [ ] 7.4 手動 smoke：對 3–5 封真實信跑 `export_emails_markdown`（含 include_attachments），確認 markdown 格式、附件分流、manifest 正確。
