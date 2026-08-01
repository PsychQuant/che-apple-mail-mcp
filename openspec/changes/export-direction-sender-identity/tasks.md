# Tasks: export-direction-sender-identity

> 本清單整體實現 spec requirement「Export direction derived per email from sender identity」（specs/batch-operations/spec.md）：group 1–2 落實 per-email 判定與 fail-open 揭露、group 3 落實 mailbox 參數降級、group 4 落實 frozen frontmatter 迴歸保證。

## 1. RED — 先寫失敗測試（鎖定 per-email direction 契約）

- [x] 1.1 在 `Tests/CheAppleMailMCPTests/ExportEmailsMarkdownTests.swift` 新增 sender-identity 判定測試：own set 含 `user@gmail.com`、三封信（一封 sender 為 own、兩封他人）匯出後，own-sender 檔含 `direction: sent`、其餘兩檔含 `direction: received`，且三個 manifest item 的 JSON 皆無 `direction_inferred` key。以現行 `run(direction:)` 簽名下此測試無法編譯或必然失敗為 RED 證據（跑 `xcrun swift test --filter ExportEmailsMarkdownTests` 確認 RED）。
- [x] 1.2 同檔新增 case-insensitive 測試：sender `User@GMAIL.com`（含 display name `"Che Cheng" <…>`）vs own set `{user@gmail.com}` → 檔案含 `direction: sent`（驗證：`xcrun swift test --filter ExportEmailsMarkdownTests`，RED）。
- [x] 1.3 同檔新增 fail-open 揭露測試：own set 為空 + `fallbackDirection: "sent"` → 兩檔皆 `direction: sent` 且每個 manifest item 的 `jsonObject` 含 `"direction_inferred": true`；對偶測項 `fallbackDirection: "received"` → 皆 `received` + 揭露（驗證：同上，RED）。

## 2. GREEN — 實作 per-email 判定 + manifest 揭露

- [x] 2.1 `Sources/CheAppleMailMCP/ExportEmailsMarkdown.swift`：`ExportManifestItem` 新增 `var directionInferred: Bool? = nil`，`jsonObject` 僅在 `true` 時輸出 `"direction_inferred": true`（鏡射 `bodyDownloaded` 的 negative-only pattern）。行為契約：成功判定路徑的 manifest 序列化不含該 key。驗證：task 1.1/1.3 的 manifest 斷言由 RED 轉 GREEN。
- [x] 2.2 實現 spec requirement「Export direction derived per email from sender identity」的核心判定：同檔 `run` 簽名 `direction: String` 改為 `ownAddresses: Set<String>`（已 lowercase）+ `fallbackDirection: String`；run loop 內於既有 `bareSender` 計算處判定 — set 非空 → `ownAddresses.contains(bareSender.lowercased()) ? "sent" : "received"`；set 空 → 每封用 `fallbackDirection` 並設該 item `directionInferred = true`。同步更新檔內既有註解（原「caller derives from mailbox」與 mixed-direction corpus 兩批註解已過時）。驗證：tasks 1.1–1.3 全部 GREEN。
- [x] 2.3 `Sources/CheAppleMailMCP/Server.swift` handler（`batch_export_emails_markdown` case）：以 `exportReader.listAccounts()` 的各帳號 `email_addresses` 聯集（lowercase）組 `ownAddresses`；現行 mailbox 字串 heuristic 保留為 `fallbackDirection`；set 為空時寫一行 stderr note（比照 #177 skip-set miss 先例）。行為契約：Gmail All Mail 匯出自寄信得 `sent` 而與 `mailbox` 字串無關。驗證：`xcrun swift build` 過 + 既有 export 整合測試維持綠。

## 3. 契約文字 — mailbox 參數降級

- [x] 3.1 `Sources/CheAppleMailMCP/Server.swift` 工具 schema：`mailbox` 參數 description 改寫為「direction 主要由 sender identity per-email 判定；mailbox 僅在 own addresses 不可得的 fallback 時作為 direction 標籤依據」。行為契約：description 不再含「only to label direction」措辭。驗證：`grep -n "only to label direction" Sources/CheAppleMailMCP/Server.swift` 回 0 hit，且新描述提及 fallback 語意。

## 4. 迴歸與收尾

- [x] 4.1 全套測試：`xcrun swift test` 0 failures（base 1090 + 新增測項），特別確認既有 frontmatter 欄位順序測試與 `body_downloaded` 測試未受影響（六欄位 frozen 契約迴歸保證）。
- [x] 4.2 `CHANGELOG.md` `## [Unreleased]` 補 #316 條目（per-email sender-identity direction + `direction_inferred` manifest 揭露 + mailbox 參數降級），並確認 `openspec/changes/export-direction-sender-identity/` artifacts 隨 PR 一併提交。驗證：content review — CHANGELOG 條目與 spec delta 語意一致。
