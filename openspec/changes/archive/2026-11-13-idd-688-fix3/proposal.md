## Summary

使用者在這次對話裡同意把信搬回收件匣，但答案寫不進紀錄檔時，這一輪照答案搬信，並在報告說明答案沒有記下來。

## Motivation

第 2 輪 verify 的第 23 列指出：規格要求「記不下來就不搬」，但 issue 把這次對話裡的回覆列為有效的同意來源，紀錄檔只是讓之後不必再問。維護者決定放寬這一點（2026-11-13）；另外兩點維持原樣：紀錄檔讀不了時不問、只列；寄件人讀不出單一位址的信不提供救回。

## Proposed Solution

plan_junk_rescue 多一個選用的參數：這一輪沒能記下來的答案。它只決定答案點名的寄件人，沒有人在場或紀錄檔有讀取錯誤時不採用。Step 9 在 record 回報 junk-decisions-write-failed 時帶著答案重算計畫並照它搬；其他錯誤照舊整批只列不動。

## Non-Goals

- 紀錄檔讀不了時仍然不問。
- 寄件人讀不出的信仍然不提供救回。

## Impact

- Affected specs: archive-mail-junk-rescue（1 條 requirement 改名並修改）
- Affected code:
  - New: (none)
  - Modified:
    - plugin/commands/archive-mail.md
    - plugin/tests/test-archive-mail-recipes.py
    - plugin/CHANGELOG.md
  - Removed: (none)
