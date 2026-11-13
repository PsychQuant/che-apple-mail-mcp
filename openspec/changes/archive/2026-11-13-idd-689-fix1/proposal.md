## Problem

`idd-689-mark-as-junk-report` 的第 1 輪審查（#689）指出四個 MEDIUM 與四個 LOW：

1. 工具描述、`mcpb/manifest.json` 與規格的描述情境寫信「stays there」。程式只保證工具自己沒有下搬移指令，不保證 Mail 不會自己搬；`is_junk` 為 true 的方向會不會搬信也沒有驗證過。
2. 回報沒有說信在哪個信箱，理由是「工具沒有查」。這個理由不成立：讀回用的訊息參照以信箱為範圍，讀回成功就表示 Mail 當下在那個信箱找到這封信。issue 選定的作法要的是「說明信仍在哪個信箱」。
3. script 形狀的測試沒有確認讀回的是同一封信，也沒有確認兩個分支各自回傳對應的值。
4. 旗標讀不回來時，回報仍請呼叫端用原來的信箱與 id 呼叫 `move_email`，而讀不回來最可能的原因就是信已經不在那裡。
5. script 把同一個訊息參照寫了兩次，讀回時要再找一次信。
6. 測試接縫只在測試正常結束時清掉。
7. CHANGELOG 把「讀回的值與要求的相反」寫成「旗標沒有變」。

## Root Cause

第一版把「工具沒有搬信」與「信沒有被搬」當成同一件事寫進描述，又把「讀回成功」能證明的事（信還在那個信箱）當成沒有證據而不寫。

## Proposed Solution

- script 先把訊息解析成一個變數，設定與讀回都用它；讀回成功就是 Mail 仍在那個信箱找到這封信的證據。
- 回報分三種：讀回的值與要求的相同（寫出 Mail 回報的值、工具沒有下搬移指令、讀回時 Mail 仍在那個信箱找到信、要搬用 `move_email`）；讀不回來（不寫旗標值、不寫信的位置，請呼叫端先重新找信再搬）；讀回的值相反（錯誤，寫出兩個值與讀回時信仍在那個信箱）。
- 工具描述改寫成「工具不下搬移指令」，不再寫信會留在原處。
- 測試比對整份 script；測試接縫改用 teardown block 清掉。

## Non-Goals

- 不讓 `mark_as_junk` 自己搬信。會在它之後自己呼叫 `move_email` 的 `/archive-mail` Step 9 還在沒有合併的 #688 分支上，不在這個分支的基底裡；查過那個分支，它不依賴 `mark_as_junk` 的回傳文字，遇到錯誤會記下來並繼續。
- 不在真的 Mail 帳號上驗證（Exchange、iCloud、`is_junk` 為 true 時 Mail 會不會自己搬信，記在 #696）。
- 逾時不在這次處理的範圍：script 超過執行期限時呼叫仍以逾時失敗，即使旗標已經改了。這次只讓讀回不必重新找信。

## Success Criteria

五個 Example 的測試照新的文字通過；script 的測試比對整份 script；`swift test` 全數通過。

## Impact

- Affected specs: junk-status-tool（四條 requirement 都修改）
- Affected code:
  - New: (none)
  - Modified:
    - Sources/CheAppleMailMCP/AppleScript/MutationToolScriptBuilder.swift
    - Sources/CheAppleMailMCP/Server.swift
    - Tests/CheAppleMailMCPTests/MutationToolScriptBuilderTests.swift
    - mcpb/manifest.json
    - README.md
    - README_zh-TW.md
    - CHANGELOG.md
  - Removed: (none)
