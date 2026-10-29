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


## #586 VIP 保護補強

分類規則批准不能覆蓋 VIP 寄件者保護。名單讀取失敗不能當成空名單；預覽與套用均重新取得 VIP 狀態，變更後拒絕舊 plan。現行 Mail 檔案尚無完整 VIP 來源的實機證據，內建 reader 只提供正向保護，未命中也視為 unknown；因此本版所有 proposed-trash 都須逐封預覽確認。上列自動分支設計仍受 VIP／來源完整性 gate 約束。此修正不變更 #585 所討論的規則批准介面，且保留所有 audit／防重派契約。
