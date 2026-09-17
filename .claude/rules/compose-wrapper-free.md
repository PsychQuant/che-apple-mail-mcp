# 建立信件：cite-block 已在結構上不可能發生（#304）

> **這條規則從「行為約束」降級為「背景說明 + 失敗處置」。**
> 產生 `<blockquote type="cite">` 的程式碼**已經不存在**。呼叫端不再需要記得帶什麼旗標、
> 不再需要判讀 result string、也不再有「這次比較方便就接受 wrapped body」這個選項——
> 那條路已經被拆掉，不是被禁止。

## 現況（#304 落地後）

四個 compose 工具的 body **只能**來自 Mail 自己的編輯器：

| 工具 | body 來源 |
|---|---|
| `compose_email` / `create_draft` | `mailto:` hand-off + GUI 鍵盤操作 |
| `reply_email` / `forward_email` | Mail 原生 reply/forward verb + 游標處貼上 |
| `forward_email`（不帶 body） | 原生 forward，**什麼都不寫入**（連 Accessibility 都不需要）|

AppleScript 的 `set content` / `set html content` / outgoing-message 建構中的 `content:`
**全部移除**，並由 `Tests/CheAppleMailMCPTests/NoBodyInjectionGuardTests.swift` 整檔掃描把關——
任何人把它們寫回來，測試就紅。

**已移除的參數**：`require_wrapper_free`（沒有 wrapper 可以「要求免於」）、
`sanitize_links`（只服務 markdown 渲染）、`format` 的 `markdown` / `html`、
以及兩個 env hatch（`CHE_MAIL_DISABLE_MAILTO_COMPOSE` / `CHE_MAIL_DISABLE_PASTE_REPLY`）。

## 呼叫失敗時怎麼辦（封閉七類，新增類別須有可驗證的作業前條件）

前提不滿足時工具**直接失敗、零副作用**（不建草稿、不寄出、不刪既有草稿），
訊息會具名原因與替代做法。七類與各自的處置：

| # | 原因 | 處置 |
|---|---|---|
| 1 | `format` 是 `markdown` / `html` | 改 `plain`。**目前沒有任何已出貨路徑**能在不注入 body 的前提下送 rich text —— 這是「現況」不是「不可能」（#310）：paste path（#218）是第二條 wrapper-free 路徑、`NSPasteboard` 也能承載 rich flavor，但它產出的 MIME 沒人驗過，由 #306 定案。替代架構見 #308 / #309 |
| 2 | subject 為空 | 給一個 subject（乾淨路徑靠視窗標題辨識自己的視窗）|
| 3 | Accessibility 未授權 | 去授權；或改用 `open_mailto`（零 TCC、**不能帶附件**、需自己存檔／寄出）|
| 4 | `from_address` 非 bare addr-spec | 給純位址；或省略後在 Mail 手動切寄件人 |
| 5 | 附件路徑含非 ASCII | 建**不帶 `attachments`** 的草稿 + 請使用者手動拖曳。**不要改成 ASCII 檔名**——收件人看到的就是那個檔名 |
| 6 | 寄出（`compose_email`）時任一收件人帶顯示名（`Name <addr>`） | 改用純位址寄出；或改建草稿（`create_draft`，**to/cc/bcc 顯示名皆支援**，#404）確認收件人後手動寄出 |
| 7 | `MAILTO_URL_TOO_LONG`：percent-encoded URL 超過 8000 字元（CJK 常見字約佔 9 個） | 先用 `check_compose_length` 精確計量 total/body/overhead。保留完整正文到本機文字檔，建立短／空正文草稿後在 Mail 手動貼上；或經使用者確認拆成多封。不要截斷、不要復活 legacy。此檢查在 Mail 作業前拒絕，update_draft 不掃描／替換／刪除舊草稿。 |

> 第 5、6 類的配方與 #304 之前的規則一致——差別是現在**工具自己會說**，不必靠人記得。

## 兩項誠實記錄的能力損失

刪掉 legacy path 不是零成本。以下兩件事**做不到了，且沒有替代方案**：

1. **不開可見視窗組信**。legacy 是唯一能在不彈出 compose 視窗的情況下建信的路徑
   （`CHE_MAIL_DISABLE_MAILTO_COMPOSE` 這個 hatch 的原始理由就是無人值守自動化）。
   mailto hand-off 必然開視窗。若日後真的成為阻塞，走 #308（IMAP APPEND），不要復活注入。
2. **`compose_email` 直接寄給 `Name <addr>`**。乾淨路徑的顯示名填入是**草稿限定**——`create_draft` /
   `update_draft` 的 to/cc/bcc **皆支援**顯示名（AX 定位聚焦 + 貼上，#404），但 `compose_email`
   （送出）仍拒絕任何顯示名收件人，因為填入失敗會在送出當下漏收件人。要保留人名 → 用 `create_draft`
   建草稿、確認收件人後手動寄出。

## TCC fallback ladder（#287）

| 階 | 路徑 | TCC 需求 | 附件 |
|----|------|----------|------|
| (a) | `create_draft` / `compose_email` | Automation + Accessibility | ✅（GUI ⇧⌘A）|
| (b) | **`open_mailto`（LaunchServices）** | **零** | ❌（RFC 6068；手動拖入）|

**AppleScript 工具回 `-1743`（Not authorized to send Apple events）時 (b) 是正解。**
signed MCP binary 自持 Automation 授權（TCC identity 綁 binary 簽章身分，與終端機 app 分開）——
**`osascript` 能用 ≠ binary 已授權**。處置：系統設定 → 隱私權與安全性 → 自動化 → 勾選該 binary 的 Mail；
找不到 entry 代表先前的 Deny 被記住，`tccutil reset AppleEvents` 後重觸發。

## 相關

- `#304` — 移除 legacy compose path（本規則現況的來源）
- `#175` — wrapper RCA + mailto 乾淨路徑；`#218` — reply/forward 的 native-verb + paste
- `#219` — 自訂寄件人；`#277` — 草稿的顯示名 To（#404 擴充至 Cc/Bcc）；`#220` — CJK 附件路徑
- `#308` / `#309` — rich-text compose 的替代架構（本規則移除 markdown/html 後的去處）
- `#404` — draft 的 Cc/Bcc 顯示名（AX 定位聚焦 + 貼上，Bcc 自動揭露不還原，存檔後 recipients_verified）
- 全域鏡像：`che-claude-config/rules/common-mail-compose.md`；
  plugin 副本：`plugin/rules/compose-wrapper-free.md`。**三份要一起改。**


## mailto 預檢（mail#388）

`check_compose_length({to, cc?, bcc?, subject, body})` 是只讀長度檢查，回傳 encoded_url_length、body_encoded_length、other_encoded_length、limit、remaining、fits。長度依 UTF-8 percent-encoding 精算，不是 body 字元數；display-name 清單依真實 URL/GUI partition 計算。`other_requirements_checked:false` 明示沒有驗證其他資格，fits=true 不是可送出承諾。
