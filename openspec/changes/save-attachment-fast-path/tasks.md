## 1. MIMEPart struct (eager decode, in-memory Data, value type)

- [x] [P] 1.1 新檔 `Sources/MailSQLite/MIMEPart.swift`，定義 `public struct MIMEPart: Sendable, Equatable` 含 `headers` / `contentType` / `contentTypeParams` / `contentDisposition` / `filename` / `rawBytes` / `decodedData` 欄位；所有欄位 `let` constant 對齊 design 的「MIMEPart struct: eager decode, in-memory Data, value type」決定
- [x] [P] 1.2 在 `Tests/MailSQLiteTests/MIMEPartTests.swift` 新增 struct 基本測試：init / Equatable / Sendable coverage；確保 decodedData 是 eager compute 而非 lazy get

## 2. MIMEParser API 演化: additive parseAllParts

- [x] 2.1 在 `Sources/MailSQLite/MIMEParser.swift` 新增 public `parseAllParts(_ bodyData: Data, headers: [String: String]) -> [MIMEPart]`，走跟 `parseBody` 相同的 multipart walking 邏輯但**不丟棄**任何 part；遵循 design 的「MIMEParser API 演化 additive parseAllParts 共存 不 refactor parseBody」決定
- [x] 2.2 `parseBody` 保持完全不變，不改為 `parseAllParts` 的 thin wrapper（避免 get_email hot path regression）
- [x] 2.3 擴充 `Tests/MailSQLiteTests/MIMEParserTests.swift` 新增 `parseAllParts` 測試：single text part、text+html、text+html+attachment、nested multipart/alternative inside multipart/mixed、exotic transfer encoding throws 的覆蓋
- [x] 2.4 新增 cross-check 測試：對同一個 multipart 輸入，`parseBody(...).textBody` 必須等於 `parseAllParts(...).first(where: text/plain)?.decodedData.string`，確保兩個 parallel API 語意一致

## 3. Content-Disposition / RFC 5987 filename parsing

- [x] [P] 3.1 在 `MIMEParser.swift` 或新 private helper 新增 Content-Disposition header 解析，支援 `filename=` / `filename*=` / RFC 2231 continuation `filename*0*=` / percent-decoded UTF-8
- [x] [P] 3.2 `Tests/MailSQLiteTests/MIMEParserTests.swift` 新增 filename 解析測試：plain ASCII / RFC 5987 UTF-8 (`filename*=UTF-8''...`) / continuation (`filename*0*=...; filename*1*=...`) / 含空格與特殊字元

## 4. AttachmentExtractor: EnvelopeIndexReader extension in MailSQLite module

- [x] 4.1 新檔 `Sources/MailSQLite/AttachmentExtractor.swift`（作為 `EnvelopeIndexReader` extension，對齊 design 的「AttachmentExtractor 位置: EnvelopeIndexReader extension, MailSQLite module」）
- [x] 4.2 在 extension 內實作 `public func saveAttachment(messageId: Int, attachmentName: String, destination: URL) throws`，流程: `EmlxParser.resolveEmlxPath` → `Data(contentsOf:)` → `EmlxFormat.extractMessageData` → `RFC822Parser.headerBodySplitOffset` → `MIMEParser.parseAllParts` → 找第一個 filename 匹配的 `MIMEPart` → `decodedData.write(to: destination)`
- [x] 4.3 實現 Match key: attachmentName (filename) first-match semantics，走完整個 parts 陣列找第一個 `filename == attachmentName || contentTypeParams["name"] == attachmentName` 的 part；不使用 SQLite attachment_id 作為 match key
- [x] 4.4 新增 typed errors: `attachmentNotFound(name:)` / `attachmentTooLarge(size:)` / MIME parse failure 複用現有 `emlxParseFailed`，確保 dispatcher 可以區分 fallback 觸發原因
- [x] 4.5 Large attachment size check: `MIMEPart.decodedData.count > 100 * 1024 * 1024` 的 match 直接 throw `attachmentTooLarge`，不寫檔，讓 dispatcher fall through AppleScript path
- [x] 4.6 驗證 mailStoragePathOverride 繼承免改動: 確認 `EmlxParser.resolveEmlxPath` 已讀 override (grep 確認)，`AttachmentExtractor` 不需額外 wiring

## 5. Server dispatcher: two-tier catch fallback strategy

- [x] 5.1 修改 `Sources/CheAppleMailMCP/Server.swift` 的 `case "save_attachment":` 分 dispatcher 成 two-tier: SQLite path 先跑且包在自己的 `do/catch`，任何 error fall through 到第二個 `do/catch` 呼叫 `MailController.saveAttachment`，對齊 design 的「Fallback 策略: two-tier catch, 與 get_email / get_emails_batch 一致」決定
- [x] 5.2 在 SQLite path catch 區塊 stderr log error cause (例如 `"SQLite save_attachment fast path failed: \(error.localizedDescription), falling through to AppleScript"`)，方便事後檢查 silent fallback
- [x] 5.3 保留 `MailController.saveAttachment` (MailController.swift:793) 不動作為 fallback，不改動 input schema

## 6. Test fixtures & integration

- [x] [P] 6.1 新增 `Tests/MailSQLiteTests/Fixtures/multipart-attachment-ascii.emlx` — multipart/mixed 含 text/plain + application/pdf base64 附件名為 `report.pdf`
- [x] [P] 6.2 新增 `Tests/MailSQLiteTests/Fixtures/multipart-attachment-cjk.emlx` — multipart/mixed 含 text/plain + application/pdf base64 附件，`Content-Disposition` 使用 `filename*=UTF-8''%E4%B8%AD%E6%96%87%E6%AA%94%E6%A1%88.pdf` 編碼
- [x] [P] 6.3 新增 `Tests/MailSQLiteTests/Fixtures/multipart-nested.emlx` — multipart/mixed 包一個 multipart/alternative (text+html) 加一個 image/png inline 附件
- [x] [P] 6.4 新增 `Tests/MailSQLiteTests/Fixtures/multipart-duplicate-filename.emlx` — 同一 email 兩個同名 attachment 驗證 first-match semantics
- [x] 6.5 新增 `Tests/MailSQLiteTests/AttachmentExtractorTests.swift` 覆蓋 spec 的 6 個 scenarios: ascii PDF / CJK filename / fallback on throw / first-match duplicate / parseAllParts 一致性 / large attachment size-based fallback
- [x] 6.6 AttachmentExtractorIntegrationTest.testFastPathReallyExecutes: 使用 fixture + mailStoragePathOverride 跑整條 `EnvelopeIndexReader.saveAttachment`，assert 寫入的 file bytes 與 fixture base64 decode 後一致、延遲 < 50ms

## 7. Documentation & release

- [x] 7.1 CHANGELOG.md 新增 `## [2.2.0] - <date>` 區段，Added: MIMEPart / parseAllParts / AttachmentExtractor.saveAttachment; Changed: save_attachment dispatcher two-tier catch (SQLite primary, AppleScript fallback); Performance: save_attachment 延遲從 1-3s 降到 < 50ms；引用 #12 與 design 的決定
- [x] 7.2 `swift test` 跑全部測試，確認 130 個既有 tests 全部通過 + 新測試通過 (156 total / 1 skipped / 0 failures)
- [ ] 7.3 `./scripts/release.sh v2.2.0 "v2.2.0: save_attachment SQLite fast path"` 發布 release 並驗證 binary asset 上傳成功
- [ ] 7.4 更新 `psychquant-claude-plugins` 的 `marketplace.json` 把 `che-apple-mail-mcp` 版本 bump 到 `2.1.2` → `2.2.0`
