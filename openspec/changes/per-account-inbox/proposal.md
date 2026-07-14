## Why

special-mailbox-resolution spec 對 per-account `inbox` 設下的 deferral 條件 —「until a live multi-account check confirms `every mailbox of inbox` exposes per-account children」— 已由 #249 的 2026-07-14 live check 滿足：7/7 帳號皆有 per-account inbox child，且 NTU Exchange 帳號實證 inbox 實名會本地化（`收件匣`），解析有真實價值。#249 追蹤（#179 task 4.2 的移轉）。

## What Changes

- `perAccountSpecialMailboxes` 增 `("inbox", "inbox")`（append 於末位，n0…n3 位置穩定）— builder/parse/handler 機構皆 count-driven，零額外邏輯
- spec：解除 deferred-inbox 條款（MODIFIED requirement + deferral scenario 改為 resolved-inbox scenario）
- `get_special_mailboxes` description 同步（inbox 入列、引 live 證據）

## Non-Goals

- outbox 維持 unified-only（D4：transient send queue、無 per-account child — 不受本 change 影響）

## Capabilities

### Modified Capabilities

- `special-mailbox-resolution`: per-account 解析涵蓋 inbox

## Impact

- Affected specs: `openspec/specs/special-mailbox-resolution/spec.md`
- Affected code: `SpecialMailboxesScriptBuilder.swift`（一行 + docs）、`Server.swift`（description）、tests
