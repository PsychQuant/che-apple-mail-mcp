# Tasks: archive-mail-identity-and-routing-merge

> 前置 #335（plugin shell 遷入本 repo）已落地；`archive-mail-attachments` 的 base spec 摘要由本 PR 帶入（來源見 verification.md）。

## 1. Identity 檔讀取 —— 實現 requirement「Machine-global identity file」（specs/archive-mail-identity/spec.md）

- [x] 1.1 在 `plugin/commands/archive-mail.md` 的「讀取搜尋擴展設定」段落之前，新增一段 identity 檔讀取指示：從 `~/.claude/.mail/identity.yaml` 讀 `participant_aliases`。缺檔時靜默繼續（不得產生警告）；檔案存在但 YAML 無法解析時，回報解析失敗並以空身份資料繼續，**不得中止歸檔**。驗收：依 spec scenario「Absent identity file is not an error」手動走一次 —— 移除該檔跑一次歸檔，run 完成且輸出無任何關於缺檔的字樣。

- [x] 1.2 落實 Decision 3：identity 檔是「另一份檔案」，不是「config 的第二層」，並實現 requirement Machine-global identity file 的 supplement 條款 —— 在同一段落定義合併規則：identity 檔的條目為基底；workspace config 的 `participant_aliases` 只補充 identity 檔未涵蓋的位址。兩邊都有的位址以 identity 檔為準。驗收：依 spec Example「Department office address resolved in an audit report」，identity 檔含 `staff@example.invalid` 而 workspace 無此鍵時，coverage audit 報告渲染出 identity 檔的顯示字串。

- [x] 1.3 落實 Decision 3：identity 檔是「另一份檔案」，不是「config 的第二層」的顯式回報要求，補齊 requirement Machine-global identity file 的衝突揭露 —— 為衝突條目加上回報：workspace config 定義了 identity 檔已有的位址時，run 報告須具名列出該位址為「已忽略的 workspace 覆寫」。**不得靜默忽略**。驗收：依 spec Example「Conflicting entry is ignored and disclosed」建構兩份檔案（identity 為 `Example Person`、workspace 為 `YF`），跑一次歸檔，確認解析結果為 `Example Person` 且報告中出現 `person@example.invalid` 的忽略提示。

## 2. Attachment routing sub-key merge —— 實現 requirement「Attachment routing configuration override granularity」（specs/archive-mail-attachments/spec.md）

- [x] 2.1 落實 Decision 4：sub-key 是 replace，不是 append，實現 requirement Attachment routing configuration override granularity —— 改寫 `plugin/commands/archive-mail.md` 中「讀取附件設定」段落的合併語意：把現行「若有，載入自訂規則（all-or-nothing 取代，不做 merge）」改為 sub-key 合併 —— 使用者未提及的 sub-key 沿用內建預設，有寫的 sub-key 整組取代（list 不做 append）。內建預設表本身維持原值不動。驗收：依 spec Example「Adding one keyword no longer requires restating the table」，config 僅寫 `document_keywords` 含 `calendar` 時，`NTUcalendar115.xlsx` 判為 document、`raw_indicators.csv` 仍判為 data。

- [x] 2.2 落實 Decision 4：sub-key 是 replace，不是 append 的 BREAKING 面，補齊 requirement Attachment routing configuration override granularity 的空清單條款 —— 在同段落寫明「省略 vs 顯式空清單」的分別：省略某個 sub-key 代表沿用預設；要停用某組預設必須寫顯式空清單。驗收：依 spec scenario「Disabling a default requires an explicit empty list」，設 `data_keywords: []` 後該 tier 不再匹配任何附件，分類落到下一 tier。

- [x] 2.3 加入未識別 sub-key 的回報規則：`attachment_routing` 下出現六個合法 sub-key（`data_extensions`、`document_extensions`、`data_keywords`、`document_keywords`、`data_dir`、`documents_dir`）以外的鍵時，回報該鍵未識別並以預設值繼續，**不得靜默接受**。驗收：塞一個 `data_dirs`（多一個 s 的常見手誤）進 config，跑一次歸檔，確認輸出點名該鍵。

## 3. 文件同步

- [x] 3.1 在 `plugin/CLAUDE.md` 的 config schema 區塊補上 identity 檔：說明它位於 `~/.claude/.mail/identity.yaml`、承載 `participant_aliases`、與 workspace config 的關係是 supplement 而非覆寫。驗收：新讀者只看 CLAUDE.md 即可回答「同一個位址兩邊都寫了，哪邊贏」。

- [x] 3.2 在 `plugin/CLAUDE.md` 的 `attachment_routing` 說明處，把現行「partial override 取代所有預設」的描述改為 sub-key 語意，並寫明省略與空清單的分別。驗收：文件描述與 task 2.1／2.2 落實的行為逐條相符（逐句對照，不得留下舊語意殘句）。

- [x] 3.3 在 `plugin/CHANGELOG.md` 新增條目，將 `attachment_routing` 語意變更標為 **BREAKING**，說明舊語意（省略即清空全部預設）與新語意（省略即沿用）的差異與遷移方式。驗收：條目本身即可讓既有使用者判斷自己的 config 是否受影響。

## 4. 迴歸與 BREAKING 影響確認

- [x] 4.1 掃過本機已知 workspace 的 `.claude/.mail/config.yaml`，逐一判定其 `attachment_routing` 寫法在新語意下行為是否改變，把結果記入實作 PR 的 description。已知：目前唯一使用該欄位的 config 採完整六 sub-key 寫法，不受影響 —— 需實際確認而非沿用此假設。 — 2026-10-23 擴大到家目錄與雲端同步資料夾，2026-10-24 補完：17 份 config 都不受影響（12 份沒寫 `attachment_routing`、5 份四個清單都寫出），6 份有 `participant_aliases` 也照原樣保留；唯一會影響它們的是比對改為不分大小寫（evidence/config-inventory-summary.json）。

- [x] 4.2 跑一次真實歸檔（既有 workspace、既有 config，不改設定），確認 identity 檔缺席時的行為與本 change 之前**逐項相同**：新歸檔封數、附件分類去向、coverage audit 結果三者一致。這是 backward-compat 的驗收依據。


## 5. 接續時的契約對帳

- [x] 5.1 驗證 Decision 1：不做 per-field 兩層 config 與 Decision 2：`own_addresses` 不進設定檔仍成立；用 diff 對帳確認只有 identity 與 routing 契約改動，未新增 generic loader 或 own_addresses 欄位。
- [x] 5.2 同步實際 alias 候選消費端 email-search-disambiguation，與 Step 1.4 / Step 7 共用 effective aliases；以候選演練及文件對帳驗證沒有舊路徑或繞過確認。
- [x] 5.3 以匿名合成 YAML 情境演練 absent / malformed / conflict / supplement 與 routing defaults / replace / [] / unknown key；記錄實際演練輸出，不取代 4.2 的真實歸檔驗收。
- [ ] 5.4 完成獨立審查、Spectra validate 與 PR 紀錄（Spectra 須在獨立副本中驗證：在 worktree 內執行時，CLI 解析到的是主 checkout 與 park 區的舊副本）。


## 6. 審查後的取捨（Decision 5，2026-10-22）

- [x] 6.1 實現 requirement「Attachment routing classifies user-written lists before retained defaults」：SOP Step 2 的分類優先序與 Step 5.5 的 classify 改為兩輪（使用者寫的清單 → 沿用內建的清單）；比對全部轉小寫，空項目丟棄。驗收：只有 spec 的兩個 scenario（`budget.xlsx`、`responses_v2.csv`）。真實歸檔的附件無法區分兩種順序（沒有一個附件會被沿用的預設搶走），所以這條順序沒有經過真實資料驗證，見 verification.md「沒有涵蓋」。
- [x] 6.2 實現 requirement「Partial routing configuration keeps unmentioned defaults」：未提及的清單沿用內建值，清單鍵寫了但沒給值等同 `[]` 並在報告揭露；BREAKING 說明改寫成機制描述，並標明受影響最大的是只寫兩個目錄的設定。
- [x] 6.3 Step 1.4：workspace alias 原樣使用、不丟棄；正規化只用於與 identity 比對；identity 內正規化重複只忽略衝突鍵；被忽略的 identity 條目不佔用地址；警告不寫原始行或顯示名稱；舊 `.claude/emails.md` 並存與在家目錄執行時各提示一行。
- [x] 6.4 Step 1.5 與 `email-search-disambiguation`：候選標來源，只來自全域 identity 的候選不標「推薦」；`--no-confirm` 時模糊人名若只有全域 identity 命中仍列候選；獨立使用 skill 時的 workspace config 解析方式寫明。
- [x] 6.5 #334 Decision C（frontmatter 記下我方帳號）另開 #535；Open Question 4（逃生口）寫入 Non-Goals。

## 7. 發佈準備

- [ ] 7.1 下一個 plugin 版本須為主版號升級（`attachment_routing` 為 BREAKING）；發佈時一併確認 `plugin/CHANGELOG.md` 的 `[Unreleased]` 條目。

## 2026-10-24 驗證進度

1.1、1.2、1.3、2.3、4.2 以最終 SOP（`229555e`）的真實 Mail 歸檔驗收（工作區副本，Mail 只讀，真實 workspace 未動）：A（改版前）與 B2（最終）在沒有 identity 檔時結果完全相同；C2 用暫時 identity 檔與部分 routing 設定，別名呈現、衝突揭露、同名不同址、未識別鍵、空值清單全部符合事先寫下的預期；`--no-confirm` 的三個情境只做了 Phase 1 乾跑。2.1、2.2 原文的驗收例子沒有出現在真實信件，改以 C2 的部分設定驗收（使用者 keyword 命中 → data、沿用的 extension → document）；「停用的清單不再命中」沒有附件可以區分。4.2 的附件去向只驗到 0 對 0。6.1 的「使用者清單勝過沿用預設」只由 spec scenario 涵蓋；6.1 打勾表示規則已寫進 SOP，不表示已用真實資料驗過。6.3、6.4 的規則由 C2 部分驗收，未涵蓋的項目列在 verification.md「沒有涵蓋」。細節見 verification.md 與 evidence/real-archive-2026-10-23.json。

## 2026-09-14 驗證進度（已被上方取代，保留作為歷史）

1.1–1.3 的 SOP 實作已完成，15 組合成演練亦通過；仍保留未勾選，因原驗收敘述要求歸檔執行與報告。4.2 真實歸檔尚未執行，Claude 四個 lens + DA 尚待登入。不得將上述項目視為已驗證，合成演練也不取代真實歸檔。
