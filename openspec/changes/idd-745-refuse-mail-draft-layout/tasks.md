## 1. 測試（RED）

- [x] 1.1 帶 Mail 草稿標記的草稿被拒絕，不開 SMTP、不寫紀錄，訊息提到 `append_draft`（Requirement: A draft is checked before it is submitted）。
- [x] 1.2 欄位名與值不分大小寫、值摺行與前後空白；同一欄位的其他值不擋。
- [x] 1.3 已提交、只剩收尾階段的 Mail 草稿照常補做。

## 2. 實作（GREEN）

- [x] 2.1 `SendDraftFlow` 第 6 項檢查與 `carriesMailsDraftMark`（用第 5 項解析出的欄位）。

## 3. 文件

- [x] 3.1 工具說明、README 兩份、CHANGELOG、manifest（工具說明由測試重產，一行）、規則檔第 5 項。
- [x] 3.2 verify 第 1、2 輪：標頭解析不了時拒絕、不當成沒有標記（第 2 輪後改為第 5、6 項共用同一次解析，由第 5 項拒絕）；拒絕訊息與 README 照實寫標記，不宣稱檢查了 MIME 結構；測試補草稿原封不動、補做兩個階段且不開 SMTP、沒有標記的 multipart 草稿照常送出。

## 4. 實際驗證（要維護者同意）

- [ ] 4.1 對一封 Mail 建立並同步到伺服器的草稿（只寄給自己）呼叫 `send_draft`，確認被拒絕、草稿原封不動。
- [ ] 4.2 允許的那條路徑（`append_draft` 建的草稿經 `send_draft` 寄出、讀收到那封信的原始內容）由 #744 的 task 4.1 一併做。
