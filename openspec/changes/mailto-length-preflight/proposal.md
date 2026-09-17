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

無。

## Impact

MailtoCompose、MailController、Server schemas、MCP tool census、compose 規則與測試；global mirror 在獨立 worktree 處理。
