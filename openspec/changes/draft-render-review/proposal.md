## Why

#305：Apple Mail 本機呈現不能代表收件端。現有 source 工具未將指定版本、測試副本與真正客戶端觀察連成可追溯流程。

## What Changes

新增 review-draft-render plugin command 與離線 MIME 審查助手。prepare 保存輸入來源的原始 bytes／指紋與已知 HTML 風險；compare 核對重新取得的來源與測試副本之 MIME 內容。真正 Gmail 檢視仍是獨立人工驗收，未完成時不得報 render PASS。

## Capabilities

### New Capabilities

- `draft-render-review`: 寄出前審查封包、來源版本／測試副本比對與客戶端驗收流程。

### Modified Capabilities

None.

## Impact

plugin/scripts/draft-render-review.py、plugin/commands/review-draft-render.md、plugin tests 與文件。不新增 MCP API，不執行網路、寄信或 HTML。
