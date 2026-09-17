## Context

mailtoEncode 只保留 ASCII unreserved，其餘 UTF-8 byte percent encode。實際 URL 是 ASCII，長度就是編碼字元數；partitionRecipientsForMailto 會把帶顯示名的清單移到 GUI，預檢必須用相同 partition。

## Goals / Non-Goals

**Goals:** 精確預檢、明確的輸入類錯誤、在 compose/draft/update 作業前拒絕。

**Non-Goals:** 不改8000上限、不新增貼上路徑、不分割或截斷正文、不修改 reply/forward 的貼上流程。

## Decisions

### 精確計量
逐 UTF-8 byte 計算 unreserved=1、其餘=3，再加 mailto:、?、subject=、&body= 及可選 cc/bcc/逗號。使用現有 recipient partition，不以中文字比例粗估。helper 回傳 encoded_url_length、body_encoded_length、other_encoded_length、limit、remaining、fits。

### 拒絕與公開工具
新增 ComposeRefusal.mailtoURLTooLong，訊息包含 MAILTO_URL_TOO_LONG、實際 total/body/limit 與手動貼上／經確認分拆指引。三個 controller 入口在任何 Mail 查詢／GUI 前檢查；composeViaMailto 組 URL 後保留同一錯誤類別。check_compose_length 只檢長度，明示 other_requirements_checked=false，不宣稱所有 eligibility 通過。

## Implementation Contract

邊界8000含等於可用，8001拒絕；body以外的subject/recipients也計入。setter/adapters不把錯誤丟進 runtime unknown-send mapper，因為在 cleanPath 前已確認零 Mail side effect。update_draft 在 locate 前拒絕，不建立或刪除舊草稿。不同合法Unicode、CRLF、顯示名分組與空cc/bcc須與buildMailtoURL長度一致。

## Risks / Trade-offs

header overhead 可能大於body，錯誤不能只說正文太長。精確長度工具不驗其他地址／權限／格式。global rule mirror 不直接覆寫使用者目前工作區；提供獨立PR，不安裝。


最終訊息另分辨 header-only overflow：當 total-body 已超過上限，要求縮短 subject／明確縮小 recipient list 或手動組信，不誤導「清空 body 就會成功」。全域鏡像由獨立 che-claude-config 工作樹 PR #17 提交，基於既有 #15，不修改原始使用者工作樹。
