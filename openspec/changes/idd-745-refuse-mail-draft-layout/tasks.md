## 1. 測試（RED）

- [x] 1.1 帶 Mail 草稿標記的草稿被拒絕，不開 SMTP、不寫紀錄，訊息提到 `append_draft`（Requirement: A draft is checked before it is submitted）。
- [x] 1.2 欄位名與值不分大小寫、值摺行與前後空白；同一欄位的其他值不擋。
- [x] 1.3 已提交、只剩收尾階段的 Mail 草稿照常補做。

## 2. 實作（GREEN）

- [x] 2.1 `SendDraftFlow` 第 6 項檢查與 `isInMailsDraftLayout`。

## 3. 文件

- [x] 3.1 工具說明、README 兩份、CHANGELOG、manifest、規則檔第 5 項。

## 4. 實際驗證（要維護者同意）

- [ ] 4.1 對一封 Mail 建立並同步到伺服器的草稿（只寄給自己）呼叫 `send_draft`，確認被拒絕、草稿原封不動。
