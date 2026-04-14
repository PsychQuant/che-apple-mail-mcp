## Why

目前 `save_attachment` 是唯一一個仍透過 AppleScript IPC 走 Mail.app 的讀取操作，每次呼叫花費 1-3 秒。同 repo 的其他讀操作（`get_email` / `list_emails` / `list_attachments`）已在 v2.0.0 遷移到 SQLite + `.emlx` fast path，延遲降到毫秒等級。兩者的延遲落差對 bulk 附件下載（例如 14 個檔案的歸檔 backfill）放大成 30 秒，直接影響 Claude Code 對話流暢度。

v2.0.0 沒有順手把 `save_attachment` 一起遷移的原因是：現有 `MIMEParser.parseBody` 是為了 `get_email` 的 text/html 用例設計的 **lossy** pipeline — 它 walk multipart 但**主動 skip 所有非 text 的 part**（`MIMEParser.swift:58-59`），而 `ParsedEmailContent` struct 也沒有 `parts` 欄位，無法 surface attachment 資料。本 change 的 root cause 是「MailSQLite module 缺少 non-lossy 的 MIME part enumeration API」，而不是 save_attachment 本身寫錯。

相關 issue：[#12](https://github.com/PsychQuant/che-apple-mail-mcp/issues/12) (動機)、[#9](https://github.com/PsychQuant/che-apple-mail-mcp/issues/9) (建立 `EmlxParser.resolveEmlxPath` 的 test hook，本 change 會繼承)。

## What Changes

- **新增 `MIMEParser.parseAllParts(_:headers:) -> [MIMEPart]` API**（additive — 不改 `parseBody`）。這個 API walk 同樣的 multipart 結構但**保留所有 parts**（text、html、attachment、inline image）並 eagerly decode transfer encoding（base64 / quoted-printable）。
- **新增 public `MIMEPart` struct**（`Sources/MailSQLite/MIMEPart.swift`）含 `headers` / `contentType` / `contentTypeParams` / `contentDisposition` / `filename` / `rawBytes` / `decodedData` 欄位。Sendable、value type、eager decode。
- **新增 `EnvelopeIndexReader.saveAttachment(messageId:attachmentName:destination:)`**（extension on `EmlxParser`，跟 `EmailContent.readEmail` 採相同 pattern）。流程：resolve `.emlx` path → `extractMessageData` → `parseHeaders` + `headerBodySplitOffset` → `parseAllParts` → 找 `filename == attachmentName` 的第一個 match → 寫 `decodedData.write(to:)`。
- **新增 `Content-Disposition` header 解析**，支援 RFC 5987 encoded filename（CJK 檔名在 Exchange / Gmail 皆常見）。放在 `MIMEParser` 內 private helper 或新檔 `ContentDispositionParser.swift`，由 MIME parser rules 決定。
- **修改 `Server.swift` 的 `save_attachment` dispatcher** 改為 SQLite-first：先試 `EnvelopeIndexReader.saveAttachment`，throw → fall through 既有 `MailController.saveAttachment`（AppleScript）。Two-tier catch pattern 對齊 `get_email` / `get_emails_batch`（#9 的 lesson：兩段 catch 不能合成一個 `do/catch`）。
- **新增 test fixture `.emlx`**（multipart with base64 attachment + CJK filename）放在 `Tests/MailSQLiteTests/Fixtures/`，重用 `mailStoragePathOverride` 的 test hook（#9 的 NSLock-guarded override）。
- **新增 `MIMEParser.parseAllParts` / `AttachmentExtractor` 單元測試**：CJK filename、base64 decode、nested multipart、multi-attachment with duplicate name（取第一個 match）、attachment not found。
- **新增效能目標驗證**：benchmark 單一附件 `save_attachment` < 50 ms（相對現在的 1-3 s）。

## Non-Goals (optional)

- **Streaming / FileHandle pipeline**: 目前整個 `.emlx` 已經 in-memory load（`EmailContent.swift:38`），單一 part decode 額外記憶體對 < 50 MB 的附件毫無壓力。大於閾值（如 100 MB）的單一 part 可由 `AttachmentExtractor` 偵測並 **fall through AppleScript path**，比 rewrite 整條 pipeline 成 streaming 簡單 100 倍。這個 hybrid 策略本 change 採用；純 streaming **不在此 scope**。
- **refactor `MIMEParser.parseBody` 變成 thin wrapper of `parseAllParts`**: 被明確拒絕。`parseBody` 是 `get_email` 讀取 hot path（`EmailContent.swift:76`），任何 signature 或 behavior 改動都會影響既有 130 個 tests。additive `parseAllParts` 是隔離的新 API，不動舊 pipeline。
- **新增 SQLite schema 或 migration**: `attachments` table 已經存在（`EnvelopeIndexReader.listAttachments` 在用），本 change 只**讀**這個 table，不做 DDL。
- **使用 envelope index 的 `attachment_id`** 作為 match key: SQLite 的 `attachment_id` 是 Mail.app 內部 ID，**對 .emlx 裡的 MIME part 層面沒有直接對應**。現有 MCP tool `save_attachment` 的 input schema 已經是 `attachment_name`，改 key 是 breaking change。維持 `attachmentName` 作為 match key，並接受 duplicate-name 時取第一個 match 的語義。
- **處理 inline image (`Content-Disposition: inline`) 的 `cid:` reference resolution**: `save_attachment` 的語義是「把 attachment 寫到磁碟」，inline image 如果有 filename 也應該能 save。但對 `cid:` 的 replacement（例如把 HTML body 裡的 `<img src="cid:...">` 改成 `file://` 路徑）不在本 change 的 scope。
- **完整的 MIME 合規覆蓋**: 本 change 專注在「拿得到 base64-encoded attachment 的 decoded bytes 寫到磁碟」，不追求 full RFC 2045 compliance。遇到 exotic encoding（例如 `uuencode` 或 `binhex`）直接 fall through 到 AppleScript。

## Capabilities

### New Capabilities

(none — 本 change 不引入新的 capability，而是在現有 `emlx-parser` capability 下加入 attachment extraction 這條 path)

### Modified Capabilities

- `emlx-parser`: 新增 "Attachment extraction from .emlx" requirement — 規範 `MIMEParser.parseAllParts` 必須保留所有 MIME parts 不做 filter，以及 `saveAttachment` 的 match-by-filename 語義、CJK filename (RFC 5987) 支援、two-tier AppleScript fallback 觸發條件、large attachment fallback 閾值。

## Impact

**Affected code**:
- `Sources/MailSQLite/MIMEParser.swift` — additive `parseAllParts` + `MIMEPart` struct (或拆到新檔 `MIMEPart.swift`)
- `Sources/MailSQLite/AttachmentExtractor.swift` — 新檔（或作為 `EmlxParser` 的 extension）含 `saveAttachment(messageId:attachmentName:destination:)`
- `Sources/MailSQLite/RFC822Parser.swift` — 若 Content-Disposition 解析會用到現有 header parsing helper，可能擴充 1-2 個 function
- `Sources/CheAppleMailMCP/Server.swift` — `save_attachment` dispatcher two-tier catch
- `Sources/CheAppleMailMCP/AppleScript/MailController.swift:793` — 既有 `saveAttachment` **保留**作為 fallback，不改動
- `Tests/MailSQLiteTests/AttachmentExtractorTests.swift` — 新檔
- `Tests/MailSQLiteTests/MIMEParserTests.swift` — 擴充（`parseAllParts` 的 case）
- `Tests/MailSQLiteTests/Fixtures/*.emlx` — 新 fixture 檔案（multipart with CJK base64 attachment）
- `CHANGELOG.md` — v2.2.0 entry
- `openspec/specs/emlx-parser/spec.md` — 透過 archive 自動更新（由 Spectra 處理）

**Affected APIs**:
- `MIMEParser` public API 新增 `parseAllParts` function + `MIMEPart` struct（向後相容，不改 `parseBody` / `ParsedEmailContent`）
- `EnvelopeIndexReader` 新增 `saveAttachment` method
- MCP tool `save_attachment` 的 **input schema 不變**（`id` / `mailbox` / `account_name` / `attachment_name` / `save_path`），只改延遲特性（1-3s → < 50ms）

**Affected systems**:
- Claude Code plugin 使用者：不需任何動作即得到 10-100x 延遲改善
- Bulk attachment workflow（例如 `/archive-mail` 的 attachment backfill）：從 30s → < 1s 級
- 測試：新增 3-5 個 `AttachmentExtractor` 測試 + 1-3 個 `MIMEParser.parseAllParts` 測試 + 1 個 fixture file；總測試數從 130 上升到 135-140
