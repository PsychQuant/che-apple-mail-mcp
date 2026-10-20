# Tasks: archive-mail-identity-and-routing-merge

> 前置：issue #335（plugin shell 遷入本 repo）必須先落地 —— 以下路徑皆為遷移後位置，且 `archive-mail-attachments` 的 base spec 隨該遷移一併移入。開工前先確認 `plugin/commands/archive-mail.md` 存在於本 repo。

## 1. Identity 檔讀取 —— 實現 requirement「Machine-global identity file」（specs/archive-mail-identity/spec.md）

- [ ] 1.1 在 `plugin/commands/archive-mail.md` 的「讀取搜尋擴展設定」段落之前，新增一段 identity 檔讀取指示：從 `~/.claude/.mail/identity.yaml` 讀 `participant_aliases`。缺檔時靜默繼續（不得產生警告）；檔案存在但 YAML 無法解析時，回報解析失敗並以空身份資料繼續，**不得中止歸檔**。驗收：依 spec scenario「Absent identity file is not an error」手動走一次 —— 移除該檔跑一次歸檔，run 完成且輸出無任何關於缺檔的字樣。

- [ ] 1.2 落實 Decision 3：identity 檔是「另一份檔案」，不是「config 的第二層」，並實現 requirement Machine-global identity file 的 supplement 條款 —— 在同一段落定義合併規則：identity 檔的條目為基底；workspace config 的 `participant_aliases` 只補充 identity 檔未涵蓋的位址。兩邊都有的位址以 identity 檔為準。驗收：依 spec Example「Department office address resolved in an audit report」，identity 檔含 `oxalislin@ntu.edu.tw` 而 workspace 無此鍵時，coverage audit 報告渲染出 identity 檔的顯示字串。

- [ ] 1.3 落實 Decision 3：identity 檔是「另一份檔案」，不是「config 的第二層」的顯式回報要求，補齊 requirement Machine-global identity file 的衝突揭露 —— 為衝突條目加上回報：workspace config 定義了 identity 檔已有的位址時，run 報告須具名列出該位址為「已忽略的 workspace 覆寫」。**不得靜默忽略**。驗收：依 spec Example「Conflicting entry is ignored and disclosed」建構兩份檔案（identity 為 `Hsu Yung-Feng`、workspace 為 `YF`），跑一次歸檔，確認解析結果為 `Hsu Yung-Feng` 且報告中出現 `yfhsu@ntu.edu.tw` 的忽略提示。

## 2. Attachment routing sub-key merge —— 實現 requirement「Attachment routing configuration override granularity」（specs/archive-mail-attachments/spec.md）

- [x] 2.1 落實 Decision 4：sub-key 是 replace，不是 append，實現 requirement Attachment routing configuration override granularity —— 改寫 `plugin/commands/archive-mail.md` 中「讀取附件設定」段落的合併語意：把現行「若有，載入自訂規則（all-or-nothing 取代，不做 merge）」改為 sub-key 合併 —— 使用者未提及的 sub-key 沿用內建預設，有寫的 sub-key 整組取代（list 不做 append）。內建預設表本身維持原值不動。驗收：依 spec Example「Adding one keyword no longer requires restating the table」，config 僅寫 `document_keywords` 含 `calendar` 時，`NTUcalendar115.xlsx` 判為 document、`raw_indicators.csv` 仍判為 data。

- [x] 2.2 落實 Decision 4：sub-key 是 replace，不是 append 的 BREAKING 面，補齊 requirement Attachment routing configuration override granularity 的空清單條款 —— 在同段落寫明「省略 vs 顯式空清單」的分別：省略某個 sub-key 代表沿用預設；要停用某組預設必須寫顯式空清單。驗收：依 spec scenario「Disabling a default requires an explicit empty list」，設 `data_keywords: []` 後該 tier 不再匹配任何附件，分類落到下一 tier。

- [x] 2.3 加入未識別 sub-key 的回報規則：`attachment_routing` 下出現六個合法 sub-key（`data_extensions`、`document_extensions`、`data_keywords`、`document_keywords`、`data_dir`、`documents_dir`）以外的鍵時，回報該鍵未識別並以預設值繼續，**不得靜默接受**。驗收：塞一個 `data_dirs`（多一個 s 的常見手誤）進 config，跑一次歸檔，確認輸出點名該鍵。

## 3. 文件同步

- [x] 3.1 在 `plugin/CLAUDE.md` 的 config schema 區塊補上 identity 檔：說明它位於 `~/.claude/.mail/identity.yaml`、承載 `participant_aliases`、與 workspace config 的關係是 supplement 而非覆寫。驗收：新讀者只看 CLAUDE.md 即可回答「同一個位址兩邊都寫了，哪邊贏」。

- [x] 3.2 在 `plugin/CLAUDE.md` 的 `attachment_routing` 說明處，把現行「partial override 取代所有預設」的描述改為 sub-key 語意，並寫明省略與空清單的分別。驗收：文件描述與 task 2.1／2.2 落實的行為逐條相符（逐句對照，不得留下舊語意殘句）。

- [x] 3.3 在 `plugin/CHANGELOG.md` 新增條目，將 `attachment_routing` 語意變更標為 **BREAKING**，說明舊語意（省略即清空全部預設）與新語意（省略即沿用）的差異與遷移方式。驗收：條目本身即可讓既有使用者判斷自己的 config 是否受影響。

## 4. 迴歸與 BREAKING 影響確認

- [x] 4.1 掃過本機已知 workspace 的 `.claude/.mail/config.yaml`，逐一判定其 `attachment_routing` 寫法在新語意下行為是否改變，把結果記入實作 PR 的 description。已知：目前唯一使用該欄位的 config 採完整六 sub-key 寫法，不受影響 —— 需實際確認而非沿用此假設。

- [ ] 4.2 跑一次真實歸檔（既有 workspace、既有 config，不改設定），確認 identity 檔缺席時的行為與本 change 之前**逐項相同**：新歸檔封數、附件分類去向、coverage audit 結果三者一致。這是 backward-compat 的驗收依據。


## 5. 接續時的契約對帳

- [x] 5.1 驗證 Decision 1：不做 per-field 兩層 config 與 Decision 2：`own_addresses` 不進設定檔仍成立；用 diff 對帳確認只有 identity 與 routing 契約改動，未新增 generic loader 或 own_addresses 欄位。
- [x] 5.2 同步實際 alias 候選消費端 email-search-disambiguation，與 Step 1.4 / Step 7 共用 effective aliases；以候選演練及文件對帳驗證沒有舊路徑或繞過確認。
- [x] 5.3 以匿名合成 YAML 情境演練 absent / malformed / conflict / supplement 與 routing defaults / replace / [] / unknown key；記錄實際演練輸出，不取代 4.2 的真實歸檔驗收。
- [ ] 5.4 完成獨立審查、Spectra validate 與 PR 紀錄；Claude OAuth 未恢復時保留五個 Claude reviewer 與真實歸檔 gate。


## 2026-09-14 驗證進度

1.1–1.3 的 SOP 實作已完成，15 組合成演練亦通過；仍保留未勾選，因原驗收敘述要求歸檔執行與報告。4.2 真實歸檔尚未執行，Claude 四個 lens + DA 尚待登入。不得將上述項目視為已驗證，合成演練也不取代真實歸檔。
