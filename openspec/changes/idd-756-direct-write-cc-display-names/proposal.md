## Why

`create_draft` 的 opt-in 直接寫入（`CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1`）只接受最簡單的呼叫：帶 Cc 或收件人顯示名稱的呼叫都改走 GUI 路徑，要開視窗、要輔助使用權限。這是 #755 「讓直接寫入盡量取代 GUI 路徑」的第 1 步（#756）。

Mail 自己存的草稿可以當範本：Cc 的資料列形狀、標頭位置、顯示名稱的存法都查證過（Diagnosis comment 7082279889、查證 comment 7082362852）。

## What Changes

- 直接寫入接受 Cc，以及 To、Cc 的顯示名稱：
  - 一份依序的收件人清單同時決定 `To:`／`Cc:` 標頭與 `recipients`、`addresses` 資料列；
  - Cc 寫成 type 1，position 接在 To 之後；
  - 名字存在 `addresses.comment`，存的是解碼後、不加引號的名字。
- `To:`／`Cc:` 只在信箱與信箱之間折疊，不切開編碼字串或引號字串。
- 名字含 CR、LF、NUL 時拒絕。這些字元會讓標頭提早結束，所以算資格不符，不做跳脫。
- 還原一筆已提交的寫入時，刪掉這次新建、且沒有被 store 裡任何資料引用的 `addresses` 列（維護者 2026-11-23 的決定，Decision comment 7082383020）。
- Bcc 改成獨立的拒絕理由（`bcc is not written directly`），照舊走 GUI 路徑。

## Non-Goals

- **Bcc**：Mail 存草稿時怎麼存 Bcc 還沒觀察到，要先做 live 實驗，另開後續。
- **空主旨**：本機沒有 Mail 存的空主旨草稿可以對照，GUI 路徑也拒絕空主旨（維護者決定，這一步不做）。
- **沒給 `from_address` 的呼叫**：Mail 的預設寄件帳號由它的 UI 依選中的信箱決定，沒有可以精確讀出的設定。
- 不改觸發、上傳確認、已讀補設（交易安全規則第 2、3、6、7、8 項的範圍）。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `message-composition`：Requirement "Direct-write draft path" 的資格清單、收件人的寫法、還原範圍。
- `compose-timing`：Requirement "Direct-write path marks" 的結果代碼 `ccOrBcc` 改為 `bcc`。

## Impact

- Affected specs: `message-composition`、`compose-timing`
- Affected code:
  - `Sources/CheAppleMailMCP/DirectDraft/DirectDraft.swift`
  - `Sources/CheAppleMailMCP/DirectDraft/DirectDraftPath.swift`
  - `Sources/MailSQLite/DraftStoreWriter.swift`
- Tests:
  - `Tests/CheAppleMailMCPTests/DirectDraftPathTests.swift`
  - `Tests/MailSQLiteTests/DraftStoreWriterTests.swift`
- Docs: `README.md`, `README_zh-TW.md`, `CHANGELOG.md`
