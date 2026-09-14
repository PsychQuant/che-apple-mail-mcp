## Why

#356 要把每次靠人重想的分類／清理判準變成可重用功能。使用者已選定自訂分類與本機判準：明確允許的規則可自動移至垃圾桶，其餘先預覽。

## What Changes

- 新增本機 classification policy、逐規則內容指紋批准與不含郵件原文的 audit。
- 新增 read-only 分類 API，回傳 category、matched rules、理由與有期限的 plan。
- 新增明確 id 清單 apply，重驗 policy／信件來源後移到原生 Trash；不永久刪除、不盲重試未知結果。
- plugin 命令協助從使用者需求草擬規則，只有使用者真正批准的規則能啟用 auto-trash。

## Capabilities

### New Capabilities

- `local-email-classification`: 個人化政策、可稽核分類與受授權約束的垃圾桶處置。

### Modified Capabilities

無。

## Impact

Swift policy／store／plan engine、Server MCP schemas/dispatch、MailController guarded move、plugin 分類命令與 confirmation 例外。依 #340 runtime stack 實作，不混入獨立歸檔 stack。
