# Confirmation Triggers — 何時要 confirm,何時可 skip

決定何時 invoke `confirmation-protocol` skill 的判斷規則。

## 必須 confirm(🔴)

### Filter 模糊
- Sender / recipient 用中文名、暱稱、角色稱呼(「陳老師」、「老闆」、「指導教授」)
- 時間用相對詞(「最近」、「上週」、「之前」)
- Scope 用通用詞(「全部」、「所有」、「整個」)

### Destructive operation
- `delete_email`、`delete_emails_batch`
- 任何修改 Mail.app 狀態的 batch 操作(`mark_as_junk_batch`、`move_emails_batch`)
- Empty Trash / Junk
- `delete_rule`、`delete_mailbox`、`delete_signature`

### Compose / Send
- `compose_email`(寄出新信)
- `reply_email`、`forward_email`、`redirect_email`
- 任何 outbound side effect

### Bulk(影響 ≥ 5 emails 的任何操作)
- `archive-mail` 預期會歸檔 ≥ 5 封
- `mark_read` 一次標 ≥ 5 封
- `move_email` 批次移動 ≥ 5 封

## 建議 confirm(🟡)

### 影響 1-4 emails 的 destructive 操作
- 單一 email 的 `delete_email` (建議 confirm,但 user 可以設定 skip)
- 單一 email 的 `mark_as_junk` (建議 confirm)

### Filter 看起來精確但範圍很大
- Sender 是明確 email 但 search 結果 > 50 封 → confirm「真的要全部處理嗎?」

## 可以 skip confirm(🟢)

### Read-only 操作
- `search_emails`、`list_emails`、`list_mailboxes`、`list_accounts`
- `get_email`、`list_attachments`、`get_email_metadata`
- 任何 query 不修改 state 的 op

### 明確指定的 single op
- 給定 Message-ID 的 `mark_read`(單封)
- 給定 Message-ID 的 `unflag_email`(單封)
- 用戶明確說「直接執行,不要問我」

### Idempotent 操作
- 重複跑不會造成額外 side effect(例如已歸檔的信再 archive 會 skip)

## 判斷流程

```
operation request
  ↓
是否有模糊 filter?
  ├─ Yes → confirmation-protocol Phase 1 (disambiguation)
  └─ No → continue

  ↓
是否 destructive 或 compose?
  ├─ Yes → confirmation-protocol Phase 3 (operation confirmation)
  └─ No → continue

  ↓
影響 emails 數 ≥ 5?
  ├─ Yes → bulk-operation-preview (Phase 2 + 3)
  └─ No → 直接執行
```

## User override

User 可以用以下說法 skip confirmation:
- 「直接做」、「不要問」、「OK 直接執行」(僅該次有效)
- `--no-confirm` 之類的 flag(if command supports)

但即使 user 說 skip,仍然應該:
- Destructive op 仍展示 op summary(但不要等 confirm)
- Compose 仍 show 信件草稿(但 send 後再說)

## 例外情況

- **Reset / cleanup 工具**:例如「清空 Trash」這種 user 明確意圖 destructive 的 op,可以信任 user(但仍 show 影響範圍)
- **Test mode**:如果 plugin 跑在 test mode,可以 skip 所有 confirmation(by env flag)

## 相關

- `skills/confirmation-protocol/SKILL.md` — 主 skill workflow
- `skills/email-search-disambiguation/SKILL.md` — Phase 1
- `skills/bulk-operation-preview/SKILL.md` — Phase 2+3
- `rules/false-positive-detection.md` — Search 結果 false positive 標示
