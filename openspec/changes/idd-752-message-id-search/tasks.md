## 1. 程式與測試

- [x] 1.1 `messageIDSearchTerms`／`messageIDCriterion`：帶角括號在前、不帶在後，一次 `OR`；`drafts(withMessageID:)` 與 `sentCopyExists` 都用它。
- [x] 1.2 `replyText`：SwiftMail 的 `message` 已帶代碼時不再加一次。

## 2. 驗證

- [ ] 2.1 全套測試、跨模型驗證、本機 CI 閘門。
- [x] 2.2 Live（iCloud，不寄信）：以草稿的 Message-ID 呼叫 `send_draft`，找到草稿（之後被 check 6 拒絕，因為那是 Mail 存的草稿）。

## 3. 實際驗證（要維護者說「測」）

- [ ] 3.1 #744 task 4.1：Mail 關著，`append_draft` 建草稿，再用回傳的 `message_id` 以 `send_draft` 寄出（只寄給自己）。
