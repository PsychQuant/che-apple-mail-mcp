## Why

#237 證實 compose_email / create_draft 在 mailto ineligible 或 GUI 失敗時靜默產出 wrapped body（`<blockquote type="cite">`）。#237 的揭露（result 後綴 + stderr + description）是**事後告知** — 對「乾淨 body 是硬需求」的正式信件，wrapped 草稿已產生、還要人工清理。#239 追蹤此 feature；設計於 diagnosis 收斂（unattended batch，方向同 issue Expected）。

## What Changes

- `compose_email` / `create_draft` 新增 **optional bool `require_wrapper_free`（default false）**：
  - `true` + mailto ineligible → **直接回錯誤**（具名 reason + 可行替代清單），不產出任何草稿/信件
  - `true` + clean path 嘗試後 GUI 失敗 → 錯誤 propagate，**不** fallback legacy（含 #242 POSTDISPATCH 語意不變）
  - `false`（default/省略）→ 現行 graceful-fallback 行為 byte-identical（backward compatible）
- 純函式 `requireWrapperFreeRefusal(reason:)` 組錯誤文案（reason + 替代：省略 from_address／改 plain／授權 Accessibility／解除 env hatch）
- Server.swift 兩個 tool 的 inputSchema + description 增列參數說明
- message-composition spec ADDED requirement（normative）

## Non-Goals

- **不改 reply_email / forward_email**（issue scope 限 compose 家族的新建路徑；reply/forward 的 clean-path 已有 #218/#254 揭露與 send-stage 保護，strictness 參數若有需求另案）
- **不改 default 行為**（graceful fallback 仍是預設）
- **不與 #219 重疊**（sender-popup 讓 custom sender 可走乾淨路徑是另一條根治線）

## Capabilities

### Modified Capabilities

- `message-composition`: 新增 wrapper-free strictness 參數契約

## Impact

- Affected specs: `openspec/specs/message-composition/spec.md`
- Affected code: `Sources/CheAppleMailMCP/MailtoCompose.swift`（refusal helper）、`Sources/CheAppleMailMCP/AppleScript/MailController.swift`（兩站分支）、`Sources/CheAppleMailMCP/Server.swift`（schema/description/參數解析）、`Tests/CheAppleMailMCPTests/`（純函式 + #254 seam 的 production-site 測試）
- Batch context：branch stacked on idd/254（同觸 compose 模組，C-pair 序列化）
