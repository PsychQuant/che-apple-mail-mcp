---
description: 準備草稿 MIME 審查封包並追蹤真正非 Apple Mail 客戶端的人工驗收
argument-hint: "<明確草稿／帳號> [來源 .eml] [審查目錄]"
allowed-tools: mcp__plugin_che-apple-mail-mcp_mail__*, Bash(python3:*), Read, Write
---

# 寄出前的客戶端呈現審查

本流程包含「來源版本」、「測試副本內容」和「真正客戶端觀察」三種證據。離線助手不渲染 HTML、不連線、不寄信，也不會回傳客戶端呈現已通過。

## 1. 確認來源與擷取方式

要求使用者明確指定草稿與帳號。使用現有 `list_drafts`、`get_email_metadata`／`get_email_source` 讀取可用資訊，核對 account、Message-ID、主旨與草稿狀態；缺資料或有歧義就停止確認，不以全帳號最新同主旨作結論（#409）。ROWID／AppleScript id 只供當次讀取，不宣稱跨重存穩定。

將選定來源保存為**完整 RFC822 `.eml` 捕捉檔**。優先用已確認來源的原始匯出 bytes。若只有 `get_email_source` 回傳文字，可作為初步分析的 UTF-8 capture，但必須記錄 `capture_kind: tool_source_text`，不能宣稱與磁碟原始 bytes 相同；來源編碼或同步狀態未釐清前不作正式呈現驗收。`.emlx` 的 byte-count 前綴與 plist trailer 不是 RFC822，不可直接改副檔名當 `.eml`。

在使用者指定的私有位置建立新的審查目錄。不要放進版本控制、公開 issue、PR 或共用雲端；內容含完整信件。路徑參數用工具的結構化參數或正確 shell quoting，不將郵件內容插進 shell 指令。

```sh
python3 <PLUGIN_ROOT>/scripts/draft-render-review.py prepare \
  --source <source.eml> --output <新的審查目錄>
```

助手在解析時限制256個MIME節點／16層深度，並在解碼前檢查quoted-printable escape（接受CRLF/LF soft break）；不支援或破損的capture會拒絕。助手寫入 `source.eml`、`review.json`；目錄0700、檔案0600。既有目錄拒絕覆寫；失敗時可能留下不完整封包，沒有完整 metadata 就不能比較。另以私有 `context.md` 記錄來源識別、capture方式、擷取日期與使用者選擇的客戶端。這份人工紀錄不是來源認證。

風險提示是有限的檢查，不是完整安全／相容性掃描。`cite_quote` 也可能是回覆或轉寄的正常原文，不可自動刪除；先分辨新正文與原始引文。原始 HTML 不用瀏覽器自動開啟，也不下載圖片／附件資源。

## 2. 另行確認測試副本

預設討論 Gmail 網頁版，使用者可改成其他實際非 Apple Mail 客戶端。**先完成審查封包，再確認是否允許測試寄送或向另一服務上傳，以及明確的測試帳號。** 本命令的呼叫本身不等於允許外寄或上傳。

若允許測試，只用另行指定的測試收件人，不沿用正式 To/Cc/Bcc；保留正文、HTML與附件內容及相關MIME metadata。不要把「改收件人後按寄出」作用於唯一的正式草稿。建立測試副本的方式、選取與內容需先確認；本助手不提供或暗中選擇寄送方法。

保存實收副本的原始 `.eml`，包括信件被分到垃圾郵件夾的情況；Sent 不能代替實收。讀取時記錄測試信的Message-ID與實際帳號，不只靠主旨／檔名。重新保存並取得正式來源的新capture後執行：

```sh
python3 <PLUGIN_ROOT>/scripts/draft-render-review.py compare \
  --review <審查目錄> --current-source <重新取得的來源.eml> \
  --received <實收副本.eml>
```

- `source_changed`：來源capture已改變，建立新審查，不沿用舊結果。
- `content_differs`：測試副本內容不同，先查明中繼改寫、charset、附件或其他差異；不能當作原草稿已驗證。
- `ready_for_client_review`：只表示這些檔案的版本／MIME內容比對相符，**仍是 `client_render_verified:false`**，不代表live Mail身分、送達認證或呈現通過。
- 解析／檔案錯誤：unavailable，修正來源或取得完整capture，不猜測結果。

Fingerprint忽略外層傳遞headers、multipart boundary與transfer encoding表示法，但保留MIME結構、decoded leaf bytes、Content-Type/Disposition參數、Content-ID及位置資訊。這不是所有語意等價MIME的判定器，中繼改寫可能造成保守的不相符。

## 3. 真正的客戶端觀察

在實際Gmail網頁版開啟剛才確認的測試信，檢視新正文是否變成引用、粗體／斜體／連結、段落、CJK、簽名與附件／inline image；以這封信實際包含的元素為準。一般瀏覽器開啟原始HTML、Sent預覽、或本助手的相同比對，都不能代替這一步。

在私有 `observation.md` 記錄客戶端與版本／瀏覽器、日期、來源與實收的digest、實收信識別、實際觀察者與結果；截圖如含個資只留在同一私有位置。使用者口頭／文字確認要明示為人工陳述，不冒稱助手親眼驗證。

沒有實際觀察時，回報「準備／比對完成，跨客戶端驗收仍待辦」。有觀察也只描述這個來源版本、測試帳號與客戶端的結果，不宣稱所有收件者／所有客戶端一致。

正式草稿若修改、重建、換簽名或附件，必須重新審查。不要呼叫 `compose_email` 重建一封信，再沿用前一封草稿的驗收。最終正式寄送需要其自身的使用者授權；本流程不會自動寄出，檔案比較也不會鎖定Mail視窗或證明之後沒有再被修改。
