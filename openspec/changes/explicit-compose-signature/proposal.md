## Why

#322 的 compose/create_draft 沒有簽名選項或收據，呼叫端只能猜要不要在 body 重寫簽名。明確選取 Mail 原生簽名與回報結果，讓正文與原生簽名分工可預期。

## What Changes

- 新增 signature={mode: mail_default|none|named, name?}，compose/create/update 一致。
- explicit none/named 在 From 之後、附件與 dispatch 之前操作 popup_signature；named 先移除 Mail 原生簽名再選取指定名稱。
- 回報選取收據，區分選取驗證與尚未證明的本文插入；不手工拼接或刪除 body 文字。

## Capabilities

### New Capabilities

- `compose-signature-selection`: 新建／取代草稿與寄送的簽名選項、順序及收據。

### Modified Capabilities

無。

## Impact

Server schemas/dispatch、MailController、mailto compose script、plugin compose 指引及測試。reply/forward 與 rich text 支援範圍不變。
