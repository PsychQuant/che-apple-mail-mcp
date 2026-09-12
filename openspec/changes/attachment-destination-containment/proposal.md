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

無。

## Impact

Server、MailController、RaceFreeFileWriter、新增目的地能力物件及相關測試、工具描述與設定文件。不變更 export 政策或 MailSQLite 的一般用途 API。
