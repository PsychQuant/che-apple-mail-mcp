# 建立信件：已移除觸發上游引文問題的注入路徑（#304 / #310）

> **這條規則從「行為約束」降級為「背景說明 + 失敗處置」。**
> 本專案觸發多餘 `<blockquote type="cite">` 的 body 注入路徑**已經移除**。呼叫端不再需要記得帶什麼旗標、
> 不再需要判讀 result string、也不再有「這次比較方便就接受 wrapped body」這個選項——
> 那條路已經被拆掉，不是被禁止。

## 上游問題與證據界線（#310）

AppleScript 注入新正文後產生多餘引文，是已通報的上游 regression **FB11734014**，不是 Mail 必須永久維持的格式限制。[Apple Developer Forums 738842](https://developer.apple.com/forums/thread/738842) 的 2023-10 貼文附腳本與收信 raw MIME，作者表示該回報當時仍為 Open；2024-03 有 macOS 13.3.1 / Mail 16.0 無法重現的回覆，2025-01 另有 macOS 15.2 使用者回報相同症狀。

2026-09-14 核對的是公開討論，**無法確認私人 Feedback Assistant 回報目前是否仍 Open，也不能推論所有 Ventura 以後版本都會發生**。Apple 可能修正它；重評 #308 / #309 的架構取捨時，應以目標版本的收信 MIME 重驗。本專案目前仍維持 #304 移除注入路徑的決定，不因公開回覆而恢復 legacy。原生回覆／轉寄保留原信的正常引文，與這個新正文被包成引文的問題不同。

## Rich paste 的既有實驗（#306）

[#306 的 2026-07-29 結果](https://github.com/PsychQuant/che-apple-mail-mcp/issues/306#issuecomment-5112852813)記錄四種 rich variant 的草稿通過；其中 HTML 組合也在寄件備份與實收副本保留粗體、斜體、連結，且沒有多餘 wrapper。這是該次 ASCII 探針的實驗紀錄，本輪未重跑，也未驗證其他版本、CJK 或所有 flavor 的送出結果。HTML 組合含 `public.html`、Apple HTML type 與 plain-text companion，不能推廣成 HTML-only flavor 也通過。產品目前仍只接受 `plain`；實驗成功不等於已完成產品整合。

## 現況（#304 落地後）

四個 compose 工具的 body **只能**來自 Mail 自己的編輯器——唯一例外是表中最後一列，`create_draft` 的 opt-in 直接寫入（它也不經 AppleScript 內文屬性）：

| 工具 | body 來源 |
|---|---|
| `compose_email` / `create_draft` | `mailto:` hand-off + GUI 鍵盤操作 |
| `reply_email` / `forward_email` | Mail 原生 reply/forward verb + 游標處貼上 |
| `forward_email`（不帶 body） | 原生 forward，**什麼都不寫入**（連 Accessibility 都不需要）|
| `create_draft`（opt-in：`CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1`，#472／#475） | 自組 MIME 直接寫入本機資料庫（Envelope Index＋`.emlx`），**不經 Mail 編輯器、不經 AppleScript 內文屬性**；不符條件、寫入失敗、或觸發上傳失敗並還原後，退回第一列的 mailto 路徑 |

AppleScript 的 `set content` / `set html content` / outgoing-message 建構中的 `content:`
**全部移除**，並由 `Tests/CheAppleMailMCPTests/NoBodyInjectionGuardTests.swift` 整檔掃描把關——
任何人把它們寫回來，測試就紅。

**已移除的參數**：`require_wrapper_free`（已移除已知觸發方式，不再提供選擇該路徑的旗標）、
`sanitize_links`（只服務 markdown 渲染）、`format` 的 `markdown` / `html`、
以及兩個 env hatch（`CHE_MAIL_DISABLE_MAILTO_COMPOSE` / `CHE_MAIL_DISABLE_PASTE_REPLY`）。

## 呼叫失敗時怎麼辦（封閉八類，不得依性質相似類推第九類）

以下八類屬 GUI 路徑。`create_draft` 的 opt-in 直接寫入（#472／#475）建立草稿時，第 3 類（Accessibility）與第 8 類（長度）不適用；直接寫入沒有建立草稿時，八類照常適用。

前提不滿足時工具**直接失敗、零副作用**（不建草稿、不寄出、不刪既有草稿），
訊息會具名原因與替代做法。八類與各自的處置：

| # | 原因 | 處置 |
|---|---|---|
| 1 | `format` 是 `markdown` / `html` | 改 `plain`。產品尚未整合 rich paste；#306 已有草稿及 HTML 組合寄送通過的實驗紀錄，不能再稱為不可能或完全未驗證。證據範圍見上節；替代架構見 #308 / #309 |
| 2 | subject 為空 | 給一個 subject（乾淨路徑靠視窗標題辨識自己的視窗）|
| 3 | Accessibility 未授權 | 去授權；或改用 `open_mailto`（零 TCC、**不能帶附件**、需自己存檔／寄出）|
| 4 | `from_address` 非 bare addr-spec | 給純位址；或省略後在 Mail 手動切寄件人 |
| 5 | 附件路徑含非 ASCII | 建**不帶 `attachments`** 的草稿 + 請使用者手動拖曳。**不要改成 ASCII 檔名**——收件人看到的就是那個檔名 |
| 6 | 寄出（`compose_email`）時任一收件人帶顯示名（`Name <addr>`） | 改用純位址寄出；或改建草稿（`create_draft`，**to/cc/bcc 顯示名皆支援**，#404）確認收件人後手動寄出 |
| 7 | `signature` 為 `named`，但名稱在 Mail 裡不存在或不只一個（`SIGNATURE: name is missing or ambiguous in Mail`，#322） | 用 `list_signatures` 找出確切名稱；或改用 `mode: none`，自己在正文寫署名 |
| 8 | `MAILTO_URL_TOO_LONG`：percent-encoded URL 超過 8000 字元（CJK 常見字約佔 9 個） | 先用 `check_compose_length` 精確計量 total/body/overhead。或帶 `from_address` 用 create_draft 的 opt-in 直接寫入（沒有長度上限；只在伺服器開了直接寫入、且呼叫符合其條件時）；或把完整正文保留在使用者選的地方，建立短／空正文草稿後在 Mail 手動貼上；或經使用者確認拆成多封。不要截斷、不要復活 legacy。此檢查在 GUI 路徑的任何 GUI 操作前拒絕（compose_email 與 update_draft 在任何 Mail 查詢前）；create_draft 的直接寫入建立草稿時不受此限（#388 verify），update_draft 不掃描／替換／刪除舊草稿。 |

> 第 5、6 類的配方與 #304 之前的規則一致——差別是現在**工具自己會說**，不必靠人記得。

## 兩項誠實記錄的能力損失

刪掉 legacy path 不是零成本。以下兩件事在 GUI 路徑上**做不到了**（第 1 件在 opt-in 直接寫入的適用範圍內例外）：

1. **不開可見視窗組信**。legacy 是唯一能在不彈出 compose 視窗的情況下建信的路徑
   （`CHE_MAIL_DISABLE_MAILTO_COMPOSE` 這個 hatch 的原始理由就是無人值守自動化）。
   mailto hand-off 必然開視窗。若日後真的成為阻塞，走 #308（IMAP APPEND），不要復活注入。
   **例外**：`create_draft` 的 opt-in 直接寫入（`CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1`，#472／#475）不開視窗、也不需要 Accessibility（改為需要 Full Disk Access 與 Automation），但只在呼叫符合 spec〈Direct-write draft path〉列出的全部條件時（適用條件與寫入前閘門兩份封閉清單，以 spec 為準，這裡不重抄）；任一條件不符就走 GUI 路徑，仍必然開視窗。
2. **`compose_email` 直接寄給 `Name <addr>`**。乾淨路徑的顯示名填入是**草稿限定**——`create_draft` /
   `update_draft` 的 to/cc/bcc **皆支援**顯示名（AX 定位聚焦 + 貼上，#404），但 `compose_email`
   （送出）仍拒絕任何顯示名收件人，因為填入失敗會在送出當下漏收件人。要保留人名 → 用 `create_draft`
   建草稿、確認收件人後手動寄出。

## TCC fallback ladder（#287）

| 階 | 路徑 | TCC 需求 | 附件 |
|----|------|----------|------|
| (a) | `create_draft` / `compose_email` | Automation + Accessibility | ✅（GUI ⇧⌘A）|
| (a′) | `create_draft` 的 opt-in 直接寫入（`CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1`，只在符合 spec〈Direct-write draft path〉全部條件時）| Full Disk Access + Automation | ❌（附件不在適用條件內）|
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

## 具名收件人：逗號格式與剪貼簿

顯示名含 ASCII 逗號時必須加引號，例如 `"Doe, Jane" <jane@example.test>`；也可改用裸位址。這是輸入格式驗證，不是新增一類資格理由。[mail #411](https://github.com/PsychQuant/che-apple-mail-mcp/issues/411)

`create_draft`／`update_draft` 的 To／Cc／Bcc 任一份清單只要有具名項目，**該份完整清單**（包含混合的裸位址與 Bcc 位址）就會在 GUI 填入期間短暫經過系統剪貼簿。其他剪貼簿工具或 Universal Clipboard 可能依系統設定取得內容；程式嘗試還原原剪貼簿，不能撤回已被讀取或同步的資料。

若不能接受這條路徑，將該份清單全部改用裸位址，或在 Mail 手動輸入。不要把剪貼簿還原當成保密保證。AXValue 的單一 token 寫入結果不足以證明可逐次追加多個 token；目前保留已使用的 paste／token-count 流程，不宣稱 AX 替代已驗證。

## mailto 預檢（mail#388）

`check_compose_length({to, cc?, bcc?, subject, body})` 是只讀長度檢查，回傳 encoded_url_length、body_encoded_length、other_encoded_length、limit、remaining、fits。長度依 UTF-8 percent-encoding 精算，不是 body 字元數；display-name 清單依真實 URL/GUI partition 計算。`other_requirements_checked:false` 明示沒有驗證其他資格，fits=true 不是可送出承諾。
