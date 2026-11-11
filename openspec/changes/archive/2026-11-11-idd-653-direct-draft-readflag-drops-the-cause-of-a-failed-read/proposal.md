## Problem

`DraftStoreWriter.readFlag` 用 `try?` 讀 `messages.read`，讀取失敗與資料列已不存在都變成 nil，失敗的原因沒有寫到任何地方（#653）。呼叫端 `ensureRead` 把 nil 當成「還讀不到」，所以結果仍然誠實（最後是 unknown），但讀取一直失敗時，stderr 上看不出原因。`uploadState` 在 #630 已經改成經 `logReadFailure` 寫出原因。

## Root Cause

`readFlag` 是單一運算式 `(try? scalarInt(...))?.map { $0 != 0 } ?? nil`；#618 之後 `scalarInt` 對任何讀取失敗都會拋錯，`try?` 把它吞掉。

## Proposed Solution

- `readFlag` 改成 do/catch：讀取拋錯時經 `logReadFailure("messages.read", error)` 寫到 stderr 並回 nil；讀取成功但沒有那一列時回 nil、不寫 stderr。簽名不變。
- 規格：Requirement: Direct-write draft path 的已讀檢查那一段，寫出「讀不到旗標的那一次查看，把原因寫到 stderr；找不到資料列的那一次不寫」。
- 兩個測試（讀取失敗寫 stderr；資料列不在不寫）。

## Non-Goals (optional)

- 不改 `ensureRead`、`attemptSteps`（凍結段）與 `readOutcome`；nil 仍代表「讀不到」，結果不變。
- 不去重：一直失敗時最多 12 行（4 次加 8 次），與 `uploadState` 同一量級。
- `schemaDrift` 讀 `sqlite_sequence` 的同類問題另有追蹤（#659），不在這裡。

## Success Criteria

- `messages` 表讀不到時，`readFlag` 回 nil，stderr 有 `messages.read read failed`。
- 資料列不存在時，`readFlag` 回 nil，stderr 沒有任何輸出。

## Impact

- Affected specs: `message-composition`
- Affected code: `Sources/MailSQLite/DraftStoreWriter.swift`, `Tests/CheAppleMailMCPTests/DirectDraftPathOutcomeTests.swift`, `.claude/rules/direct-write-transaction-safety.md`, `CHANGELOG.md`
