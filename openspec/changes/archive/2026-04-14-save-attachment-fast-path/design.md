## Context

`che-apple-mail-mcp` 的所有讀取操作在 v2.0.0 (`ff2f33a`) 遷移到 SQLite envelope index + 直接 `.emlx` 解析的 fast path 之後，延遲從秒級降到毫秒級。但 **`save_attachment` 被漏掉**——它仍透過 AppleScript 要求 Mail.app 執行 `save att in POSIX file "..."`，每次 IPC round-trip 約 1-3 秒。對單一附件下載使用者可能無感，但 bulk 情境（例如 [#12](https://github.com/PsychQuant/che-apple-mail-mcp/issues/12) 報的 14 個附件 backfill 花 30 秒）直接拖慢 Claude Code 對話。

### 為什麼 v2.0.0 沒順手遷移

當時 `MIMEParser` 是為 `get_email` 的 text/html 用例設計的 **lossy** pipeline——`MIMEParser.swift:58-59` 明確 `// Non-text parts (attachments, images) — skip`，而 `ParsedEmailContent` struct 也只有 `textBody` / `htmlBody`。要支援 attachment 需要：

1. 新增**不丟 parts** 的 parse 模式
2. 新增 **MIME part 的結構化 type**（含 headers, disposition, filename, decoded bytes）
3. 新增 **Content-Disposition / RFC 5987 filename** 處理
4. 新增 **二進位 payload 的寫檔流程**

這 4 項任一都超出 v2.0.0 原本 "SQLite search + filesystem reads" 的 scope，所以當時選擇 defer。

### 現況的 code topology

```
Server.swift:928  save_attachment dispatcher
     │
     └─▶ MailController.saveAttachment (AppleScript, 1-3s)
            └─▶ tell Mail.app → save att in POSIX file …

[v2.0.0 遷移過的其他 path, for contrast]
Server.swift:X    get_email / list_attachments
     │
     └─▶ EnvelopeIndexReader + EmlxParser.readEmail (SQLite + direct read, <50ms)
            └─▶ EmlxFormat.extractMessageData
            └─▶ RFC822Parser.parseHeaders
            └─▶ MIMEParser.parseBody (LOSSY — text/html only)
```

Fast path 已有 3 個 building blocks（`EmlxFormat`, `RFC822Parser`, `MIMEParser`），只缺 attachment enumeration。

### Stakeholders

- **Claude Code users**：`/archive-mail` 或手動 batch download 使用者會直接感受到 10-100x 改善
- **Plugin MCP client**：`save_attachment` input schema 不變，migration invisible
- **既有 130 個測試**：不能 regression

## Goals / Non-Goals

**Goals:**

1. **把 `save_attachment` 平均延遲從 1-3 秒降到 < 50 ms**（相對 `list_attachments` 的 metadata read 同量級）
2. **提供 non-lossy MIME parsing API**（`parseAllParts`）不破壞既有 `parseBody`（那是 `get_email` hot path）
3. **兩條 path 共存**：SQLite fast path as primary，AppleScript 保留作為 fallback（offline mode / exotic encoding / >100 MB 超大檔）
4. **CJK filename 正確處理**（RFC 2231 / RFC 5987 encoded filename），因為 Exchange / Gmail 中 CJK 附件名常見
5. **零 API breakage**：MCP tool `save_attachment` 的 input schema、`ParsedEmailContent` struct、`MIMEParser.parseBody` 都保持不變

**Non-Goals:**

1. **Streaming / FileHandle pipeline**：整條 pipeline 仍 in-memory。這是 YAGNI——99% 附件 < 20 MB，記憶體毫無壓力。> 100 MB 的 exotic 情境 fall through AppleScript（Mail.app 自己會 streaming）。
2. **完整 RFC 2045/2046 compliance**：只做 base64 / quoted-printable / 7bit/8bit/binary 四種 transfer encoding；遇到 `uuencode` / `binhex` 等 exotic encoding fall through AppleScript
3. **Inline image (`Content-Disposition: inline`) 的 `cid:` resolution**：`save_attachment` 語義是寫檔，不是 HTML 重寫。inline image 若有 filename 仍會正確 save，但 HTML body 裡的 `<img src="cid:...">` 改寫**不在 scope**
4. **SQLite schema migration**：只讀既有的 `attachments` table（`EnvelopeIndexReader.listAttachments` 已在讀），不做 DDL
5. **Refactor `parseBody` 成 `parseAllParts` 的 filter**：明確拒絕。`parseBody` 是 hot path，任何 behavior 改動都要重跑全部 130 個 tests。Additive 路徑的代價是兩個平行 entry point 要維護語意一致，這由測試覆蓋

## Decisions

### `MIMEParser` API 演化：additive `parseAllParts` 共存，不 refactor `parseBody`

**Decision**: 新增 `parseAllParts(_ bodyData, headers) -> [MIMEPart]` 作為獨立的 public entry point。`parseBody` 內部實作維持不變（不改成 `parseAllParts().filterText()` 的 thin wrapper）。

**Why**:
- `parseBody` 被 `EmailContent.swift:76` 呼叫，是 `get_email` / `list_emails` 等 read hot path 核心。任何 behavior 改動都必須重跑 130 個測試驗證無 regression
- 改 signature 會強迫 `ParsedEmailContent` 的 struct shape 變動，破壞 public API
- additive 路徑讓 `parseAllParts` 可以獨立演化（例如日後加 streaming 或更寬鬆的 encoding 支援），不牽動 `parseBody`

**Alternatives considered**:
- **Refactor `parseBody` 成 `parseAllParts().filterText()`**：更乾淨的 code topology，但有 hot path regression 風險。拒絕。
- **全新 module `MIMEMultipartReader`**：避免 `MIMEParser` 變兩個 entry point，但會分裂 MIME knowledge 到兩個地方。拒絕——MIME parse 語義在單一地方比較好維護一致。

**Trade-off**: `MIMEParser` 會有兩個 parallel entry point，需測試覆蓋兩者對同一輸入（例如 nested multipart with both text and attachment）產生一致的 text extraction。

### `MIMEPart` struct：eager decode、in-memory `Data`、value type

**Decision**: `MIMEPart` 包含以下欄位，全部 let constant：

```swift
public struct MIMEPart: Sendable, Equatable {
    public let headers: [String: String]              // lowercased keys
    public let contentType: String                    // "image/png" (no params)
    public let contentTypeParams: [String: String]    // charset, boundary, name, etc.
    public let contentDisposition: String?            // "attachment" / "inline" / nil
    public let filename: String?                      // RFC 2231/5987 decoded
    public let rawBytes: Data                         // raw body before decode
    public let decodedData: Data                      // after base64 / qp decode
}
```

`decodedData` **eager compute** — `parseAllParts` 就一次做完 transfer decode。

**Why**:
- Swift `Data` 是 value type with copy-on-write，parse 時算好 `decodedData` 不會多佔記憶體（只是多一個 Data view）
- Eager decode 讓 `AttachmentExtractor` 的 `decodedData.write(to:)` 是 one-liner，沒有 state machine
- `Sendable` + 所有 `let` 讓 struct 可以安全跨 concurrency domain，日後若要 parallel parse 批次附件也沒問題
- 同時保留 `rawBytes`：debug / roundtrip test / 未來若要改 lazy decode 時可以對比

**Alternatives considered**:
- **Lazy `decodedData: Data { mutating get { ... } }`**：struct 變 mutating、lose Sendable、complicates concurrency. 拒絕。
- **Streaming `InputStream`**：需要重寫 `parseAllParts` 支援 partial buffer input，設計成本高，且 p99 使用情境 < 20 MB 沒有實際收益。拒絕，作為 Non-Goal 記錄。
- **不保留 rawBytes 只存 decodedData**：省點記憶體但失去 debug 能力。拒絕——Data 是 COW，多一個欄位成本極小。

**Trade-off**: 對 100 MB+ 的超大附件，eager decode 會花 CPU 時間（base64 decode 大約 300 MB/s）而無法 cancel。以此設計，> 100 MB 的單一 part 應該在 `saveAttachment` 層 size check 後 fall through AppleScript path。這個閾值由實作層決定（見 fallback decision）。

### `AttachmentExtractor` 位置：`EnvelopeIndexReader` 的 extension，放 `MailSQLite` module

**Decision**: 新檔 `Sources/MailSQLite/AttachmentExtractor.swift`（或直接作為 `EnvelopeIndexReader` 的 extension），public API：

```swift
extension EnvelopeIndexReader {
    public func saveAttachment(
        messageId: Int,
        attachmentName: String,
        destination: URL
    ) throws
}
```

**Why**:
- 跟 `EmailContent.swift` 用 `extension EmlxParser { public static func readEmail(...) }` 的既有 pattern 一致
- `EnvelopeIndexReader.listAttachments(messageId:)` 已存在於同個 type，`saveAttachment` 是自然配對
- MailSQLite module 已有 MIMEParser、EmlxFormat、EmailContent，attachment extraction 是同層 domain code，不該跨 module 散落

**Alternatives considered**:
- **獨立新 module `MailAttachmentExtractor`**：可 spin out 成獨立 Swift package，但目前沒這個 need，MailSQLite 本身也還沒 spun out。拒絕作為 premature optimization。
- **放 CheAppleMailMCP 層**：不對。MCP 層只該做 tool dispatch + AppleScript fallback，不該寫 MIME logic。

**Trade-off**: `EnvelopeIndexReader` 的職責範圍微微擴大——從「SQLite envelope index 讀取」擴大到「讀取 + 透過 SQLite metadata 解 .emlx」。這個方向其實跟 `EmailContent.swift` (L16 extension on `EmlxParser`) 是一樣的——composition 而不是 strict separation。

### Match key：`attachmentName` (filename)，不用 SQLite `attachment_id`

**Decision**: `saveAttachment` 的 match key 是 `attachmentName: String`。parse 完 MIME 後 iterate 所有 parts 找 `filename == attachmentName` 或 `contentTypeParams["name"] == attachmentName` 的**第一個** match。

**Why**:
- 既有 MCP tool `save_attachment` 的 input schema 已是 `attachment_name`——改成 `attachment_id` 是 breaking change
- 既有 AppleScript 路徑 (`MailController.swift:793`) 也是用 filename match——API 契約對齊
- SQLite 的 `attachment_id` 是 Mail.app 內部 attachment table ID，**對 .emlx 裡的 MIME part 沒直接對應**。我們不能用 `attachment_id` 去 lookup binary，還是得 parse MIME

**Alternatives considered**:
- **`attachment_id` as match key**：理論上能 disambiguate duplicate-name（同一封 email 裡有兩個同名 PDF）。但需要**先**在 SQLite metadata 建立 attachment_id → MIME part 的 mapping，而那需要額外的 ordering 契約（例如 "envelope index 掃描順序 = MIME part 出現順序"），這個契約 Apple 沒承諾。拒絕。
- **`filename` + `occurrence: Int = 0` tiebreaker param**：加 API 複雜度換 rare edge case，YAGNI。拒絕。

**Trade-off**: 同一 email 有多個同名 attachment 時只能拿第一個。使用者需求目前沒有這個 case——若未來出現，可加 `occurrence` parameter 作為 additive extension。

### Fallback 策略：two-tier catch，與 `get_email` / `get_emails_batch` 一致

**Decision**: `Server.swift:928` 的 `save_attachment` dispatcher 用 two-tier `do/catch`（不是單一 `do/catch`）：

```swift
case "save_attachment":
    // Tier 1: SQLite + .emlx fast path
    if let reader = indexReader {
        do {
            try reader.saveAttachment(messageId: ..., attachmentName: ..., destination: ...)
            return "Attachment saved (fast path)"
        } catch {
            // Any SQLite-path error → fall through to AppleScript,
            // NOT per-item error collection. Log the cause for debugging.
        }
    }
    // Tier 2: AppleScript fallback
    return try await mailController.saveAttachment(...)
```

觸發 fallback 的 error case（全部 throw 後 fall through，不區分）：
- `MailSQLiteError.emlxNotFound`（message 還沒 indexed 或 .emlx 找不到）
- `MIMEParseError`（multipart format 有問題或 encoding 不支援）
- `AttachmentNotFoundError`（filename 在任何 MIME part 都找不到——可能 listAttachments 的 SQLite metadata 跟 .emlx 不同步）
- `LargeAttachmentError`（單一 part decoded size > 100 MB，讓 AppleScript 處理 streaming write）

**Why**:
- 直接對齊 `#9` 的 lesson：`get_emails_batch` 之前把 SQLite catch 和 AppleScript fallback 合在一個 `do/catch`，結果 SQLite throw 時 AppleScript 永遠不會跑。修法就是分成兩段 catch。新的 `save_attachment` 從一開始就用這個 pattern
- 對使用者而言：fast path 快就是快；fast path 不行就無縫 fall through 到慢但可靠的 AppleScript；不會 silent-fail

**Alternatives considered**:
- **分類 error 只對特定種 fall through**：語意更精確，但複雜度暴增且維護難——每次 MIMEParser 加新 error type 都要同步 dispatcher。拒絕 as YAGNI。
- **讓 fast path 對 large file 永遠 fall through**：先做 size check 再決定走哪條。目前選 throw `LargeAttachmentError` 讓 dispatcher 統一處理 fallback；size check 閾值放 extractor 內部是 implementation detail。

**Trade-off**: 若 SQLite path 有 bug 造成 universal throw，所有 save_attachment 會默默 fall through AppleScript，從使用者視角是「沒變快」而不是「壞掉」——需要仔細的 log 和 test 覆蓋才會及時發現。Mitigate：在 fallback 路徑 log error cause，並至少一個 integration test 驗證 fast path 真的跑成功（不是 silent fallback）。

### `mailStoragePathOverride` 繼承：免改動

**Decision**: `AttachmentExtractor` 透過 `EmlxParser.resolveEmlxPath(rowId:, mailboxURL:)` 取得 .emlx 路徑，這個 function 已經 respect `EnvelopeIndexReader.mailStoragePathOverride`（#9 的 NSLock-guarded test hook）。**不需額外 wiring**。

**Why**:
- `EmailContent.readEmail`（L30）已經透過 `resolveEmlxPath` 間接使用 override，既有測試已證明這條 path 可用
- 測試 fixture 策略直接照抄 `EmlxPathTests` 的做法——建 fake V10 tree、set override、parse、assert

**Verification during implementation**: 開工時 10 秒 grep 確認 `resolveEmlxPath` 有讀 override。若沒讀，在 extractor 處補一個 wiring。這是 implementation detail 不影響 design。

## Risks / Trade-offs

- **[Risk] `parseAllParts` 對 exotic MIME 結構（nested multipart/alternative inside multipart/mixed）可能解析失敗，silent 回傳空陣列** → Mitigation: test fixture 覆蓋至少 3 種 nesting pattern；fallback 路徑是 AppleScript，確保 user 還是能拿到 attachment
- **[Risk] CJK filename 用了 RFC 2231/5987 的 continuation encoding 但 parser 沒處理** → Mitigation: test fixture 含 `filename*=UTF-8''%E4%B8%AD%E6%96%87.pdf` 和 `filename*0*=...; filename*1*=...` 兩種形態
- **[Risk] Duplicate filename 時取第一個 match 可能跟使用者期待不符**（使用者可能認為「最後加的那個是最新版」）→ Mitigation: 在 spec 明確記錄 "first-match semantics"，若未來有 feedback 再加 `occurrence` parameter 作為 additive extension
- **[Risk] SQLite path silently fails 讓所有 save_attachment 慢性 fall through AppleScript，使用者以為沒改善** → Mitigation: fallback 路徑 stderr log `SQLite save_attachment failed: <reason>, falling through to AppleScript`；加一個 `AttachmentExtractorIntegrationTest.testFastPathReallyExecutes` assert SQLite path 真的跑過一次
- **[Trade-off] `MIMEParser` 變兩個 public entry point**（`parseBody` + `parseAllParts`）→ 必須在測試中驗證兩者對 same input 產出一致的 text body。新增 cross-check test：`parseBody(data, headers).textBody == parseAllParts(data, headers).first { $0.contentType == "text/plain" }?.decodedData.string`
- **[Trade-off] Eager decode 讓 `MIMEPart.decodedData` 對大 attachment 吃 CPU** → 100 MB 的 base64 decode 約 300 ms，超過 50 ms 延遲目標；透過 size check + AppleScript fallback 處理
