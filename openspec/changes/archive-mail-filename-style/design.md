## Context

#340 的 raw subject 與帶 offset 的 Date header 都已在匯出器內；現有預設命名卻先去掉回覆前綴並合併 dash。工作分支接在 #376 的 runtime stack，獨立 PR 僅檢視本 issue 差異。

## Goals / Non-Goals

**Goals:** opt-in 符合 archive-mail 的命名、日期同源、向後相容與磁碟碰撞保護。

**Non-Goals:** 不改預設樣式、template 的 subject 語意、舊檔案、不安裝 binary、不對真實信件歸檔、不重寫日期 parser。

## Decisions

### 選項與優先權
`filename_style` 僅接受 `default` 與 `archive-mail`，省略即 default。override → template → style。拒絕未知值與非字串，避免打錯字卻產生錯誤慣例的檔案。

### 字元與日期來源
archive 樣式使用 raw subject；逐 Swift Character 把標點、空白、斜線、反斜線與 C0/C1 控制字元映射為一個 dash。保留其他 Unicode（含 emoji 的 ZWJ），先截 50 個 Character，再去首尾 dash，空值 no-subject。不採只保留文字數字，因為會刪掉 emoji。匯出器將已轉換的 isoDate 傳給 renderer，兩者共享值；結果缺少 YYYY-MM-DD 形式的前綴時維持 unknown-date，不自行猜日期或擴充既有 parser 的日期驗證。

### 碰撞與 SOP
archive 分支產生無後綴名稱，只套既有 uniquify，不使用 legacy seen counter，避免磁碟 seed 後出現 -1-1。SOP 先檢查 tool schema 提供 archive-mail enum，支援才傳 filename_style；不支援走取得原始 Date header 的 per-email fallback。附件與索引從 manifest 取實際路徑。

## Implementation Contract

兩個 export tool 名稱共用 schema 與 dispatch。新樣式輸出 `YYYY-MM-DD_<slug>.md`，`Re: x` 對應 `Re--x`；日期由同一次 Date-header 轉換結果的前 10 碼取得。結果缺少 YYYY-MM-DD 形式的前綴時輸出 `unknown-date_<slug>.md`，frontmatter 維持 parser 原值，不能宣稱它是有效日期。所有分支保留磁碟 case-fold seed / -N 後綴與 per-item 寫檔錯誤回報。測試涵蓋東西時區跨 UTC 午夜、無效日期、Unicode 群組、截斷順序、同批跨批碰撞、選項驗證與優先權；完整 suite 回歸。SOP 不用 preview UTC 計算批次檔名。

## Risks / Trade-offs

- 原 issue 提及等待更多案例：採 opt-in + 合成案例，未宣稱額外真實歸檔驗證。
- 一個 grapheme 可以含大量 UTF-8 bytes：不私自縮短至另一套規則，超過檔案系統限制仍回報該 item 的寫檔錯誤。
- Claude OAuth 過期：可完成實作、測試與 Codex 審查，PR 維持草稿到六方審查完成。
