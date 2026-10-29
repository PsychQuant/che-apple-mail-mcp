## Why

#388 的長 mailto 目前被誤報為 scriptFailed，且註解仍假設可以退回已刪除的 legacy path。中文 percent-encoding 使普通長信容易碰到 8000 上限，需要精確預檢與可行動的具名拒絕。

## What Changes

- 精確計算 URL／body encoded length，不先組出整個 URL。
- 新增 MAILTO_URL_TOO_LONG 輸入拒絕與 check_compose_length 只讀工具。
- compose/create/update 在任何 Mail 作業前檢查，保留 8000 上限及舊有其他拒絕。
- 同步 repo、plugin 與 global mirror 說明；不自動截斷、拆寄或復活 legacy。

## Capabilities

### New Capabilities

- `mailto-length-preflight`: 編碼長度預檢、具名錯誤與無副作用拒絕。

### Modified Capabilities

- `message-composition`：封閉的拒絕清單新增長度一類；直接寫入建立草稿時，長度與 Accessibility 兩類不適用（#388 verify）。落地時疊在 #322 之上：#322 的具名簽名是第七類，長度成為第八類，清單共八類，直接寫入不適用的是第 3、8 類。主 spec 在落地時直接修改，沒有另寫 delta spec。

## Impact

MailtoCompose、MailController、Server schemas、MCP tool census、compose 規則與測試；global mirror 在獨立 worktree 處理。
