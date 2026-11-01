## Context

`reply_email` 走「原生 `reply` 動詞 + 剪貼簿貼上新內文」的乾淨路徑（#218/#304）。帶附件時，script 在貼上之後對回信物件執行 `make new attachment … at after the last paragraph`，這個指令寫入回信的 `content`，把引用原信與已貼上的內文一起洗掉，草稿只剩附件與簽名，卻回報成功（#534；#461 同症狀）。2026-11-01 的對照實驗確認差異只在附件那一步。維護者 2026-11-01 選擇：修好之前直接拒絕帶附件的 `reply_email`，第二階段（#608）再透過 Mail 編輯器附加。

現況約束：

- 不合格原因是封閉清單：spec `message-composition` 寫明「exactly the following eight, and SHALL NOT be extended by analogy」，`ComposeRefusal` 的文件註解同樣宣告封閉；規則失敗表有三份副本（兩份在本 repo，一份全域鏡像在 `che-claude-config`）。
- `replyForwardRefusal(format:accessibilityTrusted:)` 是 `reply_email` ／ `forward_email` 共用的純函式；`MailController` 的 `refusalOverride` 測試接縫會整個取代 pre-flight。
- `NoBodyInjectionGuardTests` 以整檔掃描、不理會註解的方式擋三種字面形式；註解若拼出被擋的形式也會讓測試轉紅。

## Goals / Non-Goals

**Goals:**

- `reply_email` 帶非空 `attachments` 時，在任何 AppleScript、GUI 操作與檔案檢查之前拒絕，零副作用，訊息具名原因、手動替代做法與 #608。
- 讓造成資料遺失的程式碼不存在（不是被繞過），並以守門測試防止寫回。
- spec、工具說明、兩份規則副本與 CHANGELOG 對這個暫時第九類的描述一致。

**Non-Goals:**

- 透過 ⇧⌘A 在 Mail 編輯器附加檔案、CJK 路徑的附件回信（#608）。
- `forward_email` 的附件（目前沒有這個參數）。
- #461 的 frontmost 檢查。
- 修改另一個 repo 的全域鏡像規則。
- 任何 live 執行。

## Decisions

### Refuse reply attachments as a temporary ninth reason

拒絕而不是「建草稿但說明內文沒寫進去」：#304 的契約是不合格就零副作用並具名原因，回報部分成功會讓呼叫端照樣寄出殘缺的信。新增 `ComposeRefusal.replyAttachmentsUnsupported`，文件註解標為第 9 類、暫時、只適用 `reply_email`、#608 落地時移除。spec 的封閉清單句子明文改為 nine（不是在清單後面類推加一項），並寫明第九類的適用範圍與退場條件。

替代方案：直接做第二階段。否決，因為 ⇧⌘A 路徑需要 live 驗證（L1–L4），而且依 #220 會拒絕 CJK 路徑，在那之前錯誤的成功回報會持續發生。

### Check reply attachments before every other pre-flight step

`replyForwardRefusal` 新增 `hasAttachments: Bool = false` 參數，並**最先**檢查它（在 format 與 Accessibility 之前）。理由：它只由引數決定，而且它的替代做法（不帶附件存草稿、在 Mail 手動附加）不論呼叫的其他條件為何都需要；放在最前面也讓結果與 Accessibility 授權狀態無關，生產端測試因此不必依賴機器的授權狀態。`replyEmail` 在計算出拒絕之前不做任何事：拒絕比 `validateAttachmentPaths`（讀檔案系統）更早，因此不存在的附件路徑也得到第九類而不是「not found」。由於所有非空附件都被拒絕，`replyEmail` 內的附件路徑檢查成為死碼，一併移除。`forward_email` 傳 `hasAttachments: false`（預設值），行為不變。

`refusalOverride` 接縫維持「整個取代 pre-flight」的語意，與 compose 路徑一致；生產端拒絕測試不設定這個接縫，直接走真實的 `replyForwardRefusal`。

替代方案：在 `Server.swift` 的 handler 裡檢查。否決，因為拒絕的推導集中在 `MailtoCompose.swift` 的純函式，handler 只轉送引數；handler 在呼叫 `replyEmail` 前只做引數解析與 AccountsMap plist 的反查（`resolveAccountIdForTool`），不送任何 Apple Event 給 Mail。

### Remove the object-model attachment code instead of leaving it behind the refusal

移除 `attachmentFragment`、它在 `buildReplyEmailPasteScript` 的唯一呼叫、`buildReplyEmailPasteScript` 的 `attachments` 參數、`buildReplyForwardPasteScript` 的 `needsAttachDrain` 參數與附件 drain（`CHE_MAIL_MAILTO_ATTACH_DRAIN` 在 reply／forward 路徑的使用；mailto compose 路徑的使用保留），以及只服務 `attachmentFragment` 的 `defaultDelayBetween`／`defaultDelayTrailing` 與 `CHE_MAIL_ATTACHMENT_DELAY_BETWEEN`／`_TRAILING` 環境變數讀取。`resolvedDelay` 仍供 mailto 與回信延遲使用，保留。檔頭描述 #60 的註解改寫成不拼出被禁止形式的文字。

這是 #304 的結構性做法：規則叫人別走某條路，遠弱於把那條路拆掉。

### Guard object-model attachment insertion with a source scan

新增 `NoObjectModelAttachmentGuardTests`，比照 `NoBodyInjectionGuardTests`：遞迴掃描 `Sources/CheAppleMailMCP/` 下所有 `.swift` 檔的完整文字（含註解），出現 `make new attachment` 就失敗，訊息指向 #534 與 #608。不理會註解的理由同 `NoBodyInjectionGuardTests`：只掃程式碼的守門可以被藏在多行字串裡的形式繞過。第二階段改用 ⇧⌘A 鍵盤操作，不需要這個字串，所以守門不必在 #608 移除。

spec 的「never inject a body」requirement 同步把元素插入 `content`（`make new attachment`）列為第四種禁止形式，並在 scenario 裡加上檢查項。

### Keep the attachments parameter and state the refusal in the tool description

`reply_email` 的 `attachments` 留在 schema，讓呼叫得到具名拒絕，而不是被未知參數忽略或 schema 錯誤。工具說明的「Two reasons apply here」改為「Three reasons apply here」並列出第三項（`attachments` 非空，暫時，#534／#608）；`attachments` 參數說明改為「目前一律被拒絕」與手動做法。`forward_email` 的說明維持「Two reasons」。

## Implementation Contract

- **行為**：`reply_email` 的 `attachments` 只要含至少一個元素（不論路徑是否存在、是否為 ASCII、`save_as_draft` 為何、`format` 為何、Accessibility 是否授權），呼叫就以 `MailError.invalidParameter` 失敗，訊息單行，包含：原因（附件那一步會洗掉貼上的內文與引用原信，#534）、替代做法（以 `save_as_draft: true` 且不帶 `attachments` 重新呼叫，再把檔案拖進 Mail 的撰寫視窗）、以及 #608。拒絕發生時不執行任何 AppleScript（script runner 呼叫次數為 0）、不開視窗、不建草稿、不寄信。
- **不變的行為**：`attachments` 省略或為空陣列時，`reply_email` 產生的 script 與現在不帶附件時相同；`forward_email` 不受影響。
- **介面**：`ComposeRefusal` 新增 `replyAttachmentsUnsupported`；`replyForwardRefusal(format:accessibilityTrusted:hasAttachments:)`，`hasAttachments` 預設 `false`；`buildReplyEmailPasteScript` 不再有 `attachments` 參數；`buildReplyForwardPasteScript` 不再有 `needsAttachDrain` 參數。
- **守門**：`Sources/CheAppleMailMCP/` 任何檔案含 `make new attachment` 時 `NoObjectModelAttachmentGuardTests` 失敗。
- **驗收**：`swift test` 中的拒絕單元測試、生產端零 script 測試、守門測試、說明守門測試通過；`make test` 全綠；`spectra validate refuse-reply-attachments` 通過。
- **範圍外**：⇧⌘A 附加、CJK 路徑、`forward_email` 附件、全域鏡像規則、live 執行。

## Risks / Trade-offs

- [原本以為帶附件回信「成功」的呼叫端現在會收到拒絕] → 那個成功是假的；訊息給出可執行的手動做法，CHANGELOG 標為行為變更。
- [移除 `CHE_MAIL_ATTACHMENT_DELAY_*` 會讓設定了這兩個環境變數的使用者失去效果] → 它們只控制被移除的物件模型附件路徑；compose 路徑的附件從 #304 起走 ⇧⌘A 與 `CHE_MAIL_MAILTO_*` 延遲，從未讀取這兩個變數。CHANGELOG 註明不再讀取。
- [第九類被未來的變更當成前例類推出第十類] → spec 與規則都寫明第九類只適用 `reply_email` 帶附件、#608 落地時移除，且清單仍不得類推延伸。
- [全域鏡像規則與本 repo 兩份副本暫時不一致] → 回報裡列出需要在 `che-claude-config` 做的修改，由維護者套用。
