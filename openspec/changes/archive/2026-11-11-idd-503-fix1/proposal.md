## Summary

讓 Requirement: Direct-write draft path 寫出目錄清理已經有的兩個行為：已不存在的目錄會被略過並繼續往上，以及非「不是空的」「已不存在」的移除失敗會寫到 stderr（#503 verify 第 1 輪第 1 列）。

## Motivation

#503 的實作在 `rmdir` 回 `ENOENT` 時繼續往上移除，並在其他少見的失敗時寫 stderr，但 requirement 寫的是「遇到第一個移除不了的就停」，也沒有提 stderr。verify 的 regression lens 依 #480 的規則判為 HIGH（requirement 沒有寫出的行為），Codex 與 devil's advocate 同意。requirement 自己的 scenario（移除這次建立的每一層）與程式一致，所以要改的是那一句規格，不是程式。這條行為目前也沒有測試：把 `ENOENT` 改成停下的 mutation 會通過全部測試。

## Proposed Solution

- 修改 requirement 那一句：在第一個「仍然存在而且移除不了」的目錄停下；記錄過、但已不存在的目錄略過並繼續往上；除了「不是空的」與「已不存在」以外的移除失敗寫到 stderr。
- 兩個新 Example 與測試：已不存在的 `Messages` 被略過、上層照常移除；`rmdir` 因權限失敗時寫 stderr、停下、還原仍然成功。
- 順帶修 verify 第 1 輪第 2–5 列的文字與測試：規則與 CHANGELOG 的競態前提、CHANGELOG 的過度宣稱、規則的停止條件文字、#498 那條測試補上最淺層目錄的斷言。

## Non-Goals (optional)

- 不改程式行為；`DraftStoreWriter.swift` 只可能補註解。
- verify 第 1 輪第 6–8 列（`ROLLBACK` 之前清理、目錄身分、`EEXIST` 測試）在 #666，不在這裡。

## Impact

- Affected specs: `message-composition`
- Affected code: `Tests/MailSQLiteTests/DraftStoreWriterDirectoryTests.swift`, `Tests/MailSQLiteTests/DraftStoreWriterTests.swift`, `.claude/rules/direct-write-transaction-safety.md`, `CHANGELOG.md`
