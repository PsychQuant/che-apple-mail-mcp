## 驗證紀錄（2026-09-14）

### 實作範圍

compose_email/create_draft/update_draft 共用 signature 物件（mail_default／none／named），From 之後、附件之前選取原生 popup_signature；named 僅選兩個 separator 間的簽名，排除管理 footer。None／named 均以唯一勾選項驗證，支援同名 None 簽名而不靠文字猜。附件之後、dispatch 前再核對。

收據在 dispatch 前編碼為 JSON/Base64，放在 Bcc tag 之前；Swift 先剝 Bcc 再解碼收據。selection_applied 表示執行過選取，selection_verified 是 UI 選取核對；body_insertion_verified 始終 false，不冒稱正文已插入。首次設定先確認草稿正文，或使用 none 搭配自行提供署名；不手工刪改 body 文字。

### 執行證據

- 完整 swift test：**1,331 項、11 項略過、零失敗**。
- Signature／mailto／update／cleanup 相關群組：70 項通過。
- 真正 osacompile 編譯 default／none／named+send 腳本。
- osascript 只執行純 Foundation receipt encoder 及合成清單 matcher，驗證 Unicode／惡意 marker 名稱、None vs named None、管理 footer、window id 消失／改名／大小寫／替代／前景不符。
- 真 MailController seam 驗證命名選項與收據、send 後收據缺失的未知狀態；update_draft seam 驗證新草稿傳遞選項並維持 create-before-delete。
- Spectra analyze／validate 及工具 manifest 對帳通過。

### 審查修正

Codex R1 要求 None 勾選驗證與可操作的正文指引；R2 發現既有 title-only bridge 會接手同名替代視窗。已加入原 native id/title 及前景核對。後續 cleanup 複查要求一般 GUI 錯誤也重新驗證，已在 close 前、close 後、AXRaise 後及 discard click 前補齊；身分改變時保留視窗。最終 cleanup delta 靜態複查 PASS，其他選取／收據邏輯在前次複查已通過。Reviewers 未執行測試，以上執行結果由協調者取得。

### 未完成的驗證

**尚未完整 IDD verified**：Mail 的 AX windows=0，沒有建立新真實草稿、沒有真實送出，也沒有證明指定簽名在正文的插入／移除效果。None／named 的實際 UI 結構、mark 屬性與跨版本支援仍屬 live gate。Claude OAuth 尚待登入，四個 lens + DA 未完成。

跨 Mail／AX 的 check、raise、click/close 不是原子操作，最後檢查後仍有 TOCTOU；不能宣稱完全杜絕 GUI 競態。

### 相關舊 fixture 的只讀觀察

先前 #405 的指定 outgoing subject 匹配 0；原 window id 8109 與該 subject 的配對不存在；Envelope Index 同 subject 匹配 0。因此只移除該舊 fixture 清理待辦，沒有進行刪除。這不提供 #405 stable-key 或 #322 新簽名 live gate 的證據。
