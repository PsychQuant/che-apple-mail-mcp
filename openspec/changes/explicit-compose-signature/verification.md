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


## 2026-09-17 實機與修正進度

- 真 MCP `create_draft` 的 mail_default 已驗證兩種結果：無簽名的帳號維持「無」且 saved body 等同 caller body；有預設簽名的帳號 saved body 含一份對應原生簽名。兩者都保留 caller 正文與唯一手動署名標記。原始簽名內容只在本機記憶體比較，持久證據留摘要／hash，不上傳原文。
- named 原流程在 None 區段被拒：型別化 missing value 轉字串得到字面 missing value。回歸先有兩項失敗，修正後區分空值／同名字串／錯型別。屬性讀取拋錯不能吞成空值；注入錯誤的兩項測試先 incorrectly accepted，修正後傳播精確錯誤。
- 菜單開啟時 Mail 原生 window query 在 2.20 秒逾時，關閉後約 0.13 秒成功；named 的原生 guard 因此造成 90 秒逾時。改為 native 查核包住選單生命週期、開啟期間以 PID＋AX window identity／focus 查核；錯誤先取消精確且仍屬於本次操作的選單，無法確認即保留視窗並避免 native cleanup。
- 最新 signature＋cleanup 選定測試 **25 項通過**，包含完整腳本編譯、型別、read-failure、partial-popup-scan、AX pin／focus 與 cleanup gating。Codex R4 對這批修正的靜態複查 PASS；不是完整 IDD ensemble，也不代替 native replay。
- 本輪首次完整 Swift suite 有 6 個 StdioShutdownTests 因預設 SwiftBuild 不提供舊式 Objects.LinkFileList／description.json 佈局而失敗。#377 的雙格式輔助程式修正 `3377a5b` 已合入 `56fa06a`；重跑預設建置器的完整 suite 為 **1,341 項、11 項略過、零失敗**，沒有略過原本失敗的 stdio 案例。
- 最新 named 重跑在簽名 phase 前因 AX 看不到新 compose title 而拒絕。接著 CUA 明確回報 Mac locked、automatic unlock failed，已請使用者手動解鎖。該唯一 UUID 專用草稿仍待收尾；不能標 live gate 完成。其餘本輪先前 fixture 均已驗證從 compose／outgoing／Drafts 消失；未寄送或清空 Trash。

尚待：解鎖後先收尾最新專用草稿，再跑最終 named／none 正文及失敗取消流程；完整角色審查。Claude session 額度於 02:10 後已恢復，後續排程中。OAuth 已恢復，不再以登入過期為原因。

## 2026-09-17 AX 屬性檢查的證據界線

較早的 AX 屬性探測與後來 named-r5 都取得 `_NS:41`，但前者沒有保存 window title／native id，因此不能由兩份紀錄宣稱已重現識別字重用或錯誤視窗操作。named-r5 取得指定 title 的 snapshot，AXIdentifier 與 focused identifier 相同，但 foreground 為 false，符合目前拒絕條件；尚未證實為 activation 程式錯誤。named-r4 與 named-r5 都已核對並清理，window／outgoing／Drafts 的精確比對均為 0。

目前 tracking 期間檢查的是 PID、非空 AXIdentifier、唯一精確 title、foreground 與 focused identifier；原生 window id 在選單開啟前及關閉後核對。這不是已證明的視窗生命週期身分，也未獨立證明 stored popup specifier 在視窗替換後的行為。若替代視窗保留所有比較欄位，單靠 comparator 無法分辨；後置檢查也不能撤銷先前點擊。現有單元測試只證明欄位變動會遭拒，已更正測試名稱及註解，未降低任何 runtime guard 或規格要求。

[Apple 的 accessibilityIdentifier 文件](https://developer.apple.com/documentation/appkit/nsaccessibility-c.protocol/accessibilityidentifier) 描述元素識別與自動測試用途；本案不據此推定字串跨視窗生命週期永不重用。限定 Codex 靜態審查將此裁定為 coverage／assurance gap，沒有宣稱已證實現行 Mail 可操作到錯誤視窗。

仍須完成正常 named／none／正文與取消的實機驗證，並釐清 same-title replacement／失效 popup target 的實際行為；必要時應以公開 AX API 的實體 element reference 與 ownership relationship 取代字串推定，不可用永久拒絕代替功能，也不可把假想替換當作已執行的實機測試。此處只修正證據敘述，原規格及驗收門檻維持未完成。

## 2026-09-17 整合 #333 清理歸屬檢查

合入 #356 的實機分類測試紀錄及 #333 的 cleanup ownership 修正。錯誤清理仍先確認簽名選單已關閉，之後才查詢原生 Mail；原視窗不存在時直接結束，不以同名 AX 視窗接手。原生 close 限定 id 與未改變的文字 title；AX 保留同一個精確比對目標，並在 raise 前後及 discard 前重查原生歸屬。POSTDISPATCH 分支維持不執行清理。這些查核仍不是跨 API 原子操作。

衝突整合後更新測試邊界：ownership 測試替代簽名選單關閉操作；signature 測試攔截新的原生 ownership 查詢，驗證關閉失敗時呼叫數為 0、成功時為 1。第一次測試暴露舊字串斷言與不完整 AppleScript 擷取範圍，修正測試後 **79 項重點測試通過**，包含完整 send／draft 腳本編譯。預設 SwiftBuild 完整測試 **1,366 項、12 項略過、零失敗**（316 + 1,050）。未進行真實 Mail 操作。

#322 的 named／none／正文插入移除／失敗取消實機驗證及完整獨立審查仍未完成；週額度限制仍為 Claude 的待辦原因，不是 OAuth。先前 named-r4／r5 草稿已清理，不能沿用早期「尚待解鎖清理」敘述當作目前狀態。

限定整合審查發現兩個測試缺口，已修正：選單測試改執行整段 cleanup（原生邊界以記錄呼叫的 stub 取代），AX 測試加入「精確目標在第一筆、其他視窗在最後」並沿 raise／sheet／button／click 傳遞目標身分。外部負向控制確認提前原生查詢產生 1 而非 0 次呼叫、改成錯誤目標使成功預期失敗；兩者均為實際執行後的斷言失敗，非編譯錯誤。

審查者另建議移除 `contents of`，但該 mutation 的 1 項測試仍通過。純 AppleScript `{1, 2}` 實驗確認先保存第一項 reference，迴圈結束後仍讀得 1（迴圈變數為 2），所以不把此改寫宣稱為已重現的 loop-reference 產品錯誤，也不硬造失敗結果；production 仍保留明確的 `contents of`。真實 AX reference 生命週期仍屬既有實機驗證缺口。
