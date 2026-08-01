# Design: export-direction-sender-identity

## Context

`batch_export_emails_markdown` 的 `direction` 目前是**整批單一值**：handler 在呼叫 `ExportEmailsMarkdown.run(ids:outputDir:direction:...)` 前，用 `mailbox` 參數字串做 substring heuristic（含 `sent`（case-insensitive）或 `寄件` → `"sent"`，否則 `"received"`），再把這個值原封傳給 run loop 的每一封信。Gmail 把寄出信存在 `[Gmail]/全部郵件`（雙向超集），mailbox 名稱結構上不攜帶 direction 資訊 → 自寄信全部被 frozen frontmatter 持久化成 `direction: received`（#316 實測）。

既有可用材料（discuss scout 已確認）：

- run loop 已對每封信計算 bare sender：`EmailMarkdownRenderer.bareEmail(content.sender)`（`ExportEmailsMarkdown.swift` 內、寫檔前）。
- Handler 端已 guard `indexReader != nil`（export 本來就要求 SQLite envelope index），`EnvelopeIndexReader.listAccounts()` 對每個帳號回 `email_addresses`：IMAP 型帳號（Gmail 等）的 AccountMapper 映射名是 email-form → 有地址；EWS 帳號映射名是 UUID → 空陣列（#9/#11 家族的既有誠實行為）。
- Manifest item 已有 negative-only 揭露先例：`body_downloaded: false`（`ExportManifestItem.jsonObject` 只在 false 時 emit）。

相關人：archive-mail SOP（plugin repo）是主要 caller，等本 change 落地後移除其兩批分割紀律（該修改在 plugin repo，非本 change 範圍）。

## Goals / Non-Goals

**Goals:**

- direction 對每封信正確：sender ∈ own addresses → `sent`，否則 `received`。
- 零 AppleScript：own addresses 只從 index account mapping 取（export 已是純 SQLite 路徑，不引入 IPC）。
- EWS/無資料時 fail open 到現行整批 mailbox-label 行為，export 絕不因 own addresses 缺失而失敗。
- Fall-through 可見不靜默：fallback 批的每個 manifest item 帶 `direction_inferred: true`（negative-only）。
- Frozen frontmatter 六欄位契約與順序不變。

**Non-Goals（含 rejected approaches）:**

- **選項 (b)（保留 param + per-item override）— rejected**：契約變動小但 caller 仍要做它未必做得到的 sender 判定，footgun 沒拆除。
- **選項 (c)（純文件）— rejected**：最便宜但 footgun 對所有 caller 依然上膛；#316 的實害已證明文件擋不住。
- 不改 frozen frontmatter 欄位集合（不加 `direction_source` 之類的 frontmatter 欄位 — 揭露走 manifest，不動凍結契約）。
- 不處理 alias 地址（Gmail plus-addressing、自訂網域轉寄別名不在 account mapping 內；sender 是 alias 時會標 `received` 且無揭露 — 已知殘留，現狀更糟（全部 received），不在本 change 修）。
- 不改 `list_accounts` 工具、AccountMapper、或 EWS 地址解析（那是 #9/#11 家族的既有邊界）。
- plugin repo archive-mail SOP 的 Step 5.0 修改：後續工作，不在本 repo change 內。

## Decisions

1. **Own-addresses 集合 = 全帳號聯集，非單一 `account_name` 帳號**。`exportReader.listAccounts()` 取每帳號 `email_addresses` 聯集、lowercase 化成 `Set<String>`。理由：direction 的語意是「這封是不是**使用者**寄的」，跨帳號 thread（從 B 帳號寄、歸檔在 A 帳號）用單帳號集合會漏判；且 union 免去 per-email mailboxURL → account UUID 反查的複雜度。代價：使用者 A 帳號寄給自己 B 帳號的信標 `sent` — 語意上正確（sender 確實是使用者）。
   - Alternative considered：per-email 由 `mailboxURL(forMessageId:)` 抽 account UUID → 該帳號地址。更精確地綁「該信所屬帳號」，但 direction 語意不需要這個精確度，且多一次 URL parse + 失敗面。
2. **判定位置在 `ExportEmailsMarkdown.run` 的 run loop 內，緊鄰既有 `bareSender` 計算**。`run` 簽名把 `direction: String` 換成 `ownAddresses: Set<String>`（已 lowercase）+ `fallbackDirection: String` 兩個參數：set 非空 → per-email `ownAddresses.contains(bareSender.lowercased()) ? "sent" : "received"`；set 空 → 每封都用 `fallbackDirection` 並在 manifest item 設 `directionInferred = true`。理由：direction 的消費點（frontmatter render）在 run loop 內，判定放同處最短路徑；handler 只負責組 set 與算 fallback。
   - Alternative considered：傳 closure `directionFor: (String) -> String`。更抽象但 manifest 揭露旗標仍需第二個訊號，兩參數版本把「是否 fallback」表達得更直接。
3. **揭露走 manifest item，negative-only**：`ExportManifestItem` 加 `var directionInferred: Bool? = nil`，`jsonObject` 只在 `true` 時 emit `direction_inferred: true` — 完全鏡射 `bodyDownloaded` 既有 pattern（該欄位只在 `false` 時 emit）。理由：頻道與精神都對齊既有先例；成功路徑零噪音。
4. **`mailbox` 參數降級**：工具 schema 的 `mailbox` 描述從「used only to label direction (sent when it looks like a Sent mailbox, else received)」改為說明 direction 主要由 sender identity 判定、mailbox 僅為 fail-open fallback 時的標籤依據。Handler 端保留現行 heuristic 作為 `fallbackDirection` 的計算（字串比對邏輯不變，語意從 primary 降為 fallback）。
5. **不動 `extra_frontmatter` / 六欄位渲染路徑**：`EmailMarkdownRenderer` 收到的仍是單一 `direction: String`（只是值改為 per-email 算好的），渲染層零改動。

## Implementation Contract

**Behavior（caller 可觀察）**

- 從 Gmail All Mail（或任何 mailbox）匯出時，使用者自寄的信 frontmatter 為 `direction: sent`、他人寄的為 `direction: received`，與 `mailbox` 參數字串無關 — 前提是至少一個帳號的地址可從 account mapping 解析。
- own-addresses 集合為空（如全 EWS）時，整批 direction 回到現行 mailbox-label 行為，且**每個** manifest item 多 `"direction_inferred": true`；匯出成功、不丟錯。
- sender-identity 判定成功的 manifest item **沒有** `direction_inferred` 欄位（絕不 emit `false`）。
- 比對為 bare address（display name 已剝）+ case-insensitive。
- Frontmatter 六核心欄位（`message_id`, `thread_key`, `in_reply_to`, `date`, `sender`, `direction`）名稱與順序不變；`opts.extra_frontmatter` 行為不變。

**Interface / data shape**

- `ExportEmailsMarkdown.run`：參數 `direction: String` 改為 `ownAddresses: Set<String>`（元素已 lowercase）與 `fallbackDirection: String`（`"sent"` / `"received"`）。內部 per-email direction 規則如上。此為 internal API（`static func run`），無外部 SemVer 影響。
- `ExportManifestItem`：新增 `directionInferred: Bool?`（default `nil`）；`jsonObject` 僅在 `true` 時輸出 `"direction_inferred": true`。
- Tool schema：`mailbox` 參數 description 改寫（fallback-only 語意）；input schema 欄位集合不變（不加參數、不移除參數）。
- Handler（`batch_export_emails_markdown` case）：以 `exportReader.listAccounts()` 聯集組 `ownAddresses`；`fallbackDirection` 沿用現行 mailbox 字串 heuristic。

**Failure modes**

- own-addresses 解析失敗或為空 → 靜默 fail open（整批 fallback + manifest 揭露），不寫 stderr 之外的錯誤、不中斷匯出。可加一行 stderr note（比照 #177 skip-set miss 的先例）說明走了 fallback。
- 其餘既有失敗面（write-safety、lock、fetch error）完全不變。

**Acceptance criteria**

- `Tests/CheAppleMailMCPTests/ExportEmailsMarkdownTests.swift` 新增（先 RED 後 GREEN）：
  1. own set 含 sender → 該檔 `direction: sent`、其他檔 `received`、manifest 無 `direction_inferred`（decision-table 前三列）。
  2. 大小寫混合 sender vs lowercase set → `sent`。
  3. own set 空 + `fallbackDirection: "sent"` → 兩檔皆 `sent` 且兩個 manifest item `direction_inferred == true`；`fallbackDirection: "received"` 對偶測項。
  4. 成功判定路徑的 manifest JSON 序列化不含 `direction_inferred` key。
  5. 既有 frontmatter 順序測試維持綠（六欄位契約不變的迴歸保證）。
- `xcrun swift test` 全套 0 failures（base 1090）。
- Handler 描述文字：`mailbox` description 不再含「only to label direction」措辭（grep 驗證）。

**Scope boundaries**

- In scope：`ExportEmailsMarkdown.swift`（run 簽名、run loop 判定、manifest item）、`Server.swift`（handler 組 set / fallback、`mailbox` schema description）、對應測試。
- Out of scope：`EmailMarkdownRenderer` 渲染邏輯、`EnvelopeIndexReader` schema、AccountMapper、`list_accounts` 工具、EWS 地址解析、alias 地址支援、plugin repo SOP 文件。
