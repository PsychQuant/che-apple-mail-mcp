## Why

#375：SQLite／AccountsMap 只有單一地址且缺 EWS 身分，無法完整比對已設定的寄件別名。需要可靠、可快取的帳號設定來源，且更新失敗不能再次靜默判為 received。

## What Changes

- 從 Mail 的 configured email addresses 取得有版本與筆數的 JSON snapshot，嚴格驗證並保留不完整狀態。
- 每個 server process 快取 300 秒，合併同時更新，失敗退避 60 秒，呼叫端等待預算 5 秒。
- 新增嚴格 boolean `opts.refresh_identity`，可略過快取／退避，仍共用正在進行的更新。
- 匯出使用原生地址集合處理 EWS／別名；不完整／失敗時明確標示推論及來源，保留既有降級輸出。
- 更新帳號設定 metadata 的 read-path 例外；訊息內容仍走 SQLite／emlx，不增加逐封 Apple Event。

## Capabilities

### New Capabilities

- `cached-account-identities`: 原生已設定地址、快取生命週期、匯出可信度與更新選項。

### Modified Capabilities

無。

## Impact

snapshot parser／script、cache actor、MailController、Server export、manifest／direction 說明、repo read-path 規則及測試。無地址快取落盤，無帳號設定或實際歸檔修改。
