## Why

`export_emails_markdown` 是批次歸檔的核心工具，但 #232 事故證實：LLM caller 掃 tool list 時**名字**的權重高於 description — AI 讀 archive SOP 後仍逐封呼叫 `get_email`，因為名字沒有「batch」訊號（description 首句雖已含 "Export a batch"，名字級掃描看不到）。#233 追蹤此決策；spectra-discuss（2026-07-13，記錄於 issue #233）收斂為 rename-with-deprecated-alias，使用者已採納此方向。

## What Changes

- 新增 MCP tool **`batch_export_emails_markdown`** 為 canonical 主名：與 `export_emails_markdown` **同 handler、同 input schema、同 manifest 輸出**（dispatch 雙 case label + tool list 加一 entry，零行為分歧）
- 既有 **`export_emails_markdown` 降為 DEPRECATED alias**：
  - description 前綴 `DEPRECATED — renamed to batch_export_emails_markdown; this alias will be removed in the next major release (v3.0).`（其餘 description 內容保留，行為不變）
  - 以舊名呼叫時輸出一行 stderr deprecation warn（觀測性慣例；回傳結果不變）
- tool 總數 48 → 49（過渡期；README 計數與工具表同步 — 順帶修正 README 既有 47/48 不一致）
- CHANGELOG [Unreleased] 記錄 rename + deprecation window + caller 遷移指引
- **移除 gate（normative）**：舊名移除**不得早於下一個 major（v3.0）**，寫入 batch-operations spec

**BREAKING**（延遲生效）：舊名移除發生於未來 major；本 change 本身**純 additive**（現有 caller 零斷裂）。

## Non-Goals

- **不做 hard rename**（一刀切移除舊名）— 立即斷 archive-mail SOP 與使用者 script，收益不高於 alias 方案；discuss 已排除
- **不做 description-only** — 現況首句已含 "batch"，#232 的機制是名字級掃描可見性，description-only 結構上解不了核心訴求；discuss 已排除
- **不在本 change 執行 v3.0 移除** — 移除是未來 major 的獨立 breaking change，本 change 只立 normative gate
- **不改 handler 行為 / schema / manifest** — 純名字層；任何行為變更都是 scope violation
- **不動 plugin 端 archive-mail SOP**（跨 repo）— distribution sync 時另行處理

## Capabilities

### New Capabilities

（none — 無新行為能力；名字層變更）

### Modified Capabilities

- `batch-operations`: export 條款主名改為 `batch_export_emails_markdown` + 舊名 deprecated-alias 契約（同 schema/行為、stderr warn、v3.0 移除 gate）

## Impact

- Affected specs: `openspec/specs/batch-operations/spec.md`
- Affected code: `Sources/CheAppleMailMCP/Server.swift`（tool list entry + dispatch 雙 label + 舊名 stderr warn）、`Tests/CheAppleMailMCPTests/`（雙名 schema 一致性 + deprecation 標示 guard）、`README.md`、`CHANGELOG.md`
- Merge-order 依賴：**已解決** — PR #245（#236）已 merge，本 branch 已 rebase 至 `2b73dbc`
- 跨 repo（不在本 change scope，記錄於 issue #233 Residue）：archive-mail SOP skill（psychquant-claude-plugins）於 distribution sync 改用新名
