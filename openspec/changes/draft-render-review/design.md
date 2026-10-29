## Context

#306 顯示保存草稿、送出副本與實收副本必須分開觀察。#409 仍有 Mail 身分查找限制；離線檔案指紋不能被宣稱為已鎖定某個 live compose 視窗。

## Goals / Non-Goals

Goals：保存證據、避免以舊 snapshot 或不同內容的測試信支持呈現結論，提供實際客戶端驗收順序。

Non-Goals：不模擬 Gmail；不對所有客戶端保證 HTML 一致；不自動寄測試信、改寫HTML、啟用新格式或鎖定live Mail草稿。完整#305仍須實際客戶端驗收。

## Decisions

預設以 Gmail 網頁版為可調整目標。prepare／compare 只處理使用者指定的 RFC822 .eml 檔案，byte hash 僅代表該捕捉檔。command要求來源身分與擷取方式紀錄；MCP回傳source文字不能被宣稱與磁碟原始bytes完全相同。

Fingerprint保留MIME樹結構、leaf decoded bytes、Content-Type/Disposition參數與Content-ID，忽略boundary與transfer encoding差異；外層傳遞headers不作內容等價依據。這只是實收內容比對，不是來源認證或呈現等價。

## Implementation Contract

CLI `prepare --source FILE --output NEW_DIR` 回傳review.json及source.eml；目錄0700、檔案0600，拒絕覆寫，metadata最後寫入。輸入最多16MiB，MIME最多256parts/16depth；解析節點在建立／attach時就執行part/depth上限，不等整棵樹完成；解析缺陷與不支援編碼拒絕。Quoted-printable接受ASCII hex escape及CRLF/LF soft break，拒絕bare等號、非法escape/control與行尾裸空白；這是明列的capture profile，不宣稱完整RFC conformance。

CLI `compare --review DIR --current-source FILE --received FILE` 重算snapshot並驗證manifest一致；回傳snapshot_matches、content_matches與client_render_verified=false。任一比對不符exit2，解析/檔案錯誤exit1；全相符仍只表示ready_for_client_review，不能當作render PASS。

prepare只寫固定檔名，不輸出active HTML或依附件名稱建檔。HTML風險提示為非完整heuristic：cite block、Apple wrapper、inline CSS、active markup與remote resource；不自動移除正常回覆引用。

Command只使用明確指定來源，先辨識帳號／Message-ID／主旨並告知目前是否能確認為草稿。來源不明則停止。測試寄送或向另一服務上傳前取得使用者明確同意與測試帳號；不得重用正式收件人名單。實際客戶端觀察需記錄客戶端、日期、內容一致性與人工結果；沒有觀察就維持pending。正式草稿修改或重新建立後重驗，不以compose_email重建一封信冒充已審版本。

## Risks / Trade-offs

Mail同步與capture文字轉碼會影響bytes；只陳述檔案層級比較。中繼改寫MIME可能造成保守的不相符；需調查，不能自動放行。實際Gmail測試尚待授權，功能本輪僅完成準備／比對與工作流程。
