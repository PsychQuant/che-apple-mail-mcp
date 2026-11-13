## Why

archive-mail 會把位於帳號垃圾郵件匣的信照常歸檔，之後沒有任何一步再提它；agent 只能在回報裡請使用者自己到 Mail 標成非垃圾郵件。同一個 MCP 本來就有標記與搬信的工具，這一步不必交回給使用者（#688）。

## What Changes

- Step 7 的報告列出本次歸檔、位於帳號垃圾郵件匣的信；只有末段相同的資料夾（例如使用者自建的 Clients/Junk）另列一行。
- Step 8.5 之後新增 Step 9：對還沒有紀錄的寄件人一次問全部要不要搬回收件匣；同意就標成非垃圾郵件、搬到該帳號的收件匣，再以重新搜尋讀回。
- 決定以寄件人為單位寫進每個歸檔目標的 junk_decisions.json；有紀錄的寄件人之後不再問，紀錄是 rescue 就直接搬並列在報告，是 leave 就只列出。
- 紀錄檔壞掉、或沒有人在場時，只列不動：不問、不搬、不寫紀錄。
- archive-mail 的預授權清單加入 mark_as_junk 與 move_email；鎖定清單的測試與 #395 的 Trust boundary 說明同步修改，move_email 只在 Step 9 使用、目的地只能是收件匣。
- 確認來源規則新增第四類：使用者先前的回覆留在紀錄檔裡的決定，只對這一個搬回動作有效。

## Capabilities

### New Capabilities

- `archive-mail-junk-rescue`: archive-mail 如何回報位於垃圾郵件匣的已歸檔信件、何時詢問、怎麼搬回收件匣、怎麼記住每個寄件人的決定，以及哪些情況只列不動。

### Modified Capabilities

(none)

## Impact

- Affected specs: archive-mail-junk-rescue（新增）
- Affected code:
  - New: (none)
  - Modified:
    - plugin/commands/archive-mail.md
    - plugin/rules/confirmation-triggers.md
    - plugin/tests/test-archive-mail-recipes.py
    - Tests/CheAppleMailMCPTests/CommandAllowedToolsGuardTests.swift
    - plugin/CLAUDE.md
    - plugin/CHANGELOG.md
  - Removed: (none)
