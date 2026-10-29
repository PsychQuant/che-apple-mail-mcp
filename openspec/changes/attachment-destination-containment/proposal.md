## Why

#402：寄件人可控檔名可能被呼叫端組入 `save_path`，現有附件儲存沒有 root 限制，且會先建立父目錄。所有後端必須共用可驗證的寫入邊界。

## What Changes

- **BREAKING**：附件目的地沿用 `CHE_MAIL_EXPORT_ALLOWED_ROOTS` 與既有敏感目錄拒絕清單；拒絕不安全的原始路徑元件。
- 將授權與發布從後端取得附件的重試流程分離，防止 fallback 繞過拒絕。
- AppleScript 使用私有暫存檔，逐次重試建立新暫存位置，成功後串流發布。
- 保留正常覆寫、自動建立目錄、空附件例外、帳號 UUID 與下載重試語意。

## Capabilities

### New Capabilities

- `attachment-destination-containment`: 附件寫入的授權、描述元定位及私有暫存發布。

### Modified Capabilities

- `emlx-parser`：`save_attachment` 的 dispatcher 只讓**擷取**錯誤 fallback；把擷取到的 bytes 發布到呼叫端目的地的錯誤是終止錯誤。Tier 1 讀到 0 bytes 且未帶 `allow_empty` 時當作沒讀到。

## Impact

Server、MailController、RaceFreeFileWriter、新增目的地能力物件及相關測試、工具描述與設定文件。共用政策的變更也作用於 export：雲端同步資料夾改為允許、denylist 名稱以 case folding 比對並加入 shell 啟動檔與 agent 設定、root 為 `/` 可用。不變更 MailSQLite 的一般用途 API。
