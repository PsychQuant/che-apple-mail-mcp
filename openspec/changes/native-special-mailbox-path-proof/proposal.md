## Why

#376：同父層的兩個普通資料夾能互相佐證成特殊信箱。索引只知道路徑，不能從名稱推定角色。

## What Changes

- 索引僅產生候選；每個回傳的 `_path` 必須有 Mail 原生物件比對證據。
- 移除父層票數、完整名稱及 INBOX 位置捷徑；舊 tuple 中的 path 欄位不再被信任。
- 保留 canonical account、leaf、無 selector 的 unified 輸出，以及不可驗證時省略 path 的行為。

## Capabilities

### New Capabilities

- `native-special-mailbox-path-proof`: 候選路徑的原生角色驗證。

### Modified Capabilities

無。

## Impact

Special mailbox builder／parser、MailController、Server、工具說明與測試。不讀取訊息內容，不建立或修改信箱。
