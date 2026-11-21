# che-apple-mail-mcp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-26.0%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![MCP](https://img.shields.io/badge/MCP-Compatible-green.svg)](https://modelcontextprotocol.io/)

**最完整的 Apple Mail MCP 伺服器** - 61 個工具，SQLite 驅動的毫秒級搜尋，支援 25 萬封以上郵件。

這是給你的 Apple Mail 用的 MCP：Mail 裡設好的帳號、Mail 存在這台 Mac 上的信，以及郵件伺服器上的信匣。它不一定經過 Mail 這個 App：

| 路徑 | 用在 | 需要 |
|---|---|---|
| 直接讀 Mail 的本機資料（SQLite 與 `.emlx`） | 讀信、搜尋、匯出 | 完全磁碟取用權限；資料新舊取決於 Mail 上次同步 |
| Mail App（AppleScript、撰寫視窗） | 大部分寫入：撰寫、回覆、轉寄、搬移、標記、刪除 | Mail 開著；自動化權限，撰寫另需輔助使用 |
| 直接連郵件伺服器（IMAP 與 SMTP） | `send_draft`（[#742](https://github.com/PsychQuant/che-apple-mail-mcp/issues/742)）、`append_draft`（[#744](https://github.com/PsychQuant/che-apple-mail-mcp/issues/744)） | `direct-transport.json` 的設定與 App 專用密碼；不需要 Mail 開著、不套用簽名，Mail 要等下次同步才看得到 |

[English](README.md) | [繁體中文](README_zh-TW.md)

---

## 為什麼選擇 che-apple-mail-mcp？

| 功能 | 其他 MCP | che-apple-mail-mcp |
|------|----------|-------------------|
| 工具總數 | ~20 | **61** |
| 開發語言 | Python | **Swift (原生)** |
| 搜尋速度 | 秒級 (AppleScript) | **毫秒級 (SQLite)** |
| 搜尋欄位 | 主旨/寄件人 | **主旨/寄件人/收件人/日期** |
| 批次操作 | 無 | **每次最多 50 封** |
| 信箱管理 | 基本 | 完整 CRUD |
| 郵件顏色 | 無 | 7 種旗標顏色 + 背景色 |
| VIP 管理 | 無 | 有 |
| 規則管理 | 部分 | 完整 CRUD |
| 簽名檔 | 無 | 有 |
| 原始標頭/原始碼 | 無 | 有 |

---

## 快速開始

安裝 **plugin**。它把簽章過的 binary、`/archive-mail` 系列指令、安全規則、
staleness hook 當成一整包帶進來：

```bash
claude plugin marketplace add PsychQuant/che-apple-mail-mcp
claude plugin install che-apple-mail-mcp@che-apple-mail-mcp
```

接著授予權限——設定視窗會顯示即時狀態，並直接帶你到對的系統設定頁面：

```bash
~/bin/CheAppleMailMCP --setup
```

> **💡 完全取用磁碟（Full Disk Access）** 是 SQLite 快速路徑與
> `batch_export_emails_markdown` 的前提。沒授權時工具**看起來能跑但讀不到東西**，
> 很容易被誤判成 bug 而不是權限問題。macOS 不允許程式以 API 觸發 FDA 授權對話框
> ——必須手動勾選，這正是設定視窗存在的理由。

### plugin 與「只裝 MCP」的差別

單獨註冊 MCP server 是受支援的進階路徑，但它是**嚴格更小**的安裝。要選可以，
但請**知情地選**——執行期不會有任何訊號告訴你少了這些（#353）：

| plugin 提供 | 只裝 MCP |
|---|---|
| 全部 61 個 MCP 工具 | ✅ 有 |
| `/archive-mail` 與 `-migrate` / `-rebuild-threads` / `-repair-synthetic-ids` / `-view` | ❌ 整套歸檔 SOP 不存在 |
| `rules/compose-wrapper-free.md`——正式信件的 cite-block 紀律 | ❌ **影響最大**：對正式信件產生 `<blockquote type="cite">` 本文是 CRITICAL 缺陷，而這條規則正是防它的 |
| `rules/confirmation-triggers.md`、`rules/false-positive-detection.md` | ❌ 破壞性操作沒有確認紀律 |
| `hooks/session-start.sh`——staleness kill | ❌ 升級後 session 可能仍跑舊 binary |
| Developer ID **簽章 + notarized** binary | ❌ 自行編譯是 ad-hoc 簽章；macOS 26 的 TCC 無法穩定保住 FDA/Automation，症狀是「權限給了又掉」（[#211](https://github.com/PsychQuant/che-apple-mail-mcp/issues/211)）|
| Version sidecar → `--self-update` 與 #303 staleness 自檢 | ❌ 手建 binary 旁沒有 sidecar，該自檢對你**永遠靜默無效** |

<details>
<summary><strong>進階：只註冊 MCP server</strong>（開發用，或你不想裝 plugin）</summary>

```bash
git clone https://github.com/PsychQuant/che-apple-mail-mcp.git
cd che-apple-mail-mcp
swift build -c release

# --scope user     : 跨所有專案可用（存在 ~/.claude.json）
# --transport stdio: 本地 binary 執行，透過 stdin/stdout
# --               : 分隔 claude 選項和實際執行的命令
mkdir -p ~/bin
cp .build/release/CheAppleMailMCP ~/bin/
claude mcp add --scope user --transport stdio che-apple-mail-mcp -- ~/bin/CheAppleMailMCP
```

請將 binary 安裝到本機目錄如 `~/bin/`，避免雲端同步資料夾（Dropbox、iCloud、
OneDrive）——同步活動會造成 MCP 連線逾時。

自建 binary 若要跨重新編譯保住 TCC 權限，需自行用 Developer ID 簽章；否則每次
重編都得重新授權。

</details>

---

## 全部 61 個工具

### 新建郵件的簽名

compose_email、create_draft、update_draft 支援 signature 物件：`{"mode":"mail_default"}`、`{"mode":"none"}`、`{"mode":"named","name":"Professional"}`。工具在 From 之後選取 Mail 原生簽名，不手工將簽名拼進 body。**選取收據不是正文插入證據**；首次在該 Mail 設定使用時先確認草稿，再正式寄送，或選 none 並自行提供署名。交給 Mail 插入時不要再重複手寫同一份簽名。介面／名稱無法安全辨識時 explicit mode 會拒絕，不回退到已移除的 body-assignment 路徑。

<details>
<summary><b>組信預檢 (1)</b></summary>

| Tool | Description |
|------|-------------|
| `check_compose_length` | 不存取 Mail 的精確 URL／body 編碼長度；fits 不是完整資格保證 |

</details>

<details>
<summary><b>郵件分類 (4)</b></summary>

| Tool | Description |
|------|-------------|
| `get_email_classification_policy` | 讀取本機判準與批准 |
| `configure_email_classification` | 設定判準、明確批准／撤回規則 |
| `classify_emails` | 只讀分類與短效明確 ids 計畫 |
| `apply_email_classification` | 先寫稽核並受保護地移至原生垃圾桶，不永久刪除 |

</details>

<details>
<summary><b>帳戶 (2)</b></summary>

| 工具 | 說明 |
|------|------|
| `list_accounts` | 列出所有郵件帳戶 |
| `get_account_info` | 取得帳戶詳細資訊 |

</details>

<details>
<summary><b>信箱 (4)</b></summary>

| 工具 | 說明 |
|------|------|
| `list_mailboxes` | 列出所有信箱（資料夾） |
| `create_mailbox` | 建立新信箱 |
| `delete_mailbox` | 刪除信箱 |
| `get_special_mailboxes` | 取得特殊信箱名稱（收件匣、草稿、寄件備份、垃圾桶、垃圾郵件、寄件匣） |

</details>

<details>
<summary><b>郵件 (7)</b></summary>

| 工具 | 說明 |
|------|------|
| `list_emails` | 列出信箱中的郵件 |
| `get_email` | 取得完整郵件內容 |
| `search_emails` | 依主旨/內容搜尋 |
| `get_unread_count` | 取得未讀數量 |
| `get_email_headers` | 取得所有郵件標頭 |
| `get_email_source` | 取得郵件原始碼 |
| `get_email_metadata` | 取得中繼資料（已轉寄、已回覆、大小） |

</details>

<details>
<summary><b>操作 (8)</b></summary>

| 工具 | 說明 |
|------|------|
| `mark_read` | 標記為已讀/未讀 |
| `flag_email` | 加上/移除旗標 |
| `set_flag_color` | 設定旗標顏色（7 種顏色） |
| `set_background_color` | 設定郵件背景顏色 |
| `mark_as_junk` | 標記為垃圾郵件/非垃圾郵件 |
| `move_email` | 移動到其他信箱 |
| `copy_email` | 複製到其他信箱 |
| `delete_email` | 刪除郵件（移至垃圾桶） |

</details>

<details>
<summary><b>撰寫 (7)</b></summary>

| 工具 | 說明 |
|------|------|
| `compose_email` | 撰寫新郵件（支援附件） |
| `reply_email` | 回覆郵件 |
| `forward_email` | 轉寄郵件 |
| `redirect_email` | 重導向郵件（保留原始寄件者） |
| `send_draft` | 經 SMTP 寄出伺服器草稿匣裡已有的一封草稿，不經 Mail（[#742](https://github.com/PsychQuant/che-apple-mail-mcp/issues/742)）。尚未對真實伺服器跑過。只限 `direct-transport.json` 列出的帳號，設定見下方「直接傳送（send_draft）」 |
| `append_draft` | 經 IMAP 在伺服器的草稿匣建立一封新的純文字草稿，不經 Mail（[#744](https://github.com/PsychQuant/che-apple-mail-mcp/issues/744)）。尚未對真實伺服器跑過。只限 `direct-transport.json` 列出的帳號；只收純位址；回傳 `send_draft` 可用的 `message_id`。見下方「直接傳送」 |
| `open_mailto` | 開啟 mailto URL |

</details>

<details>
<summary><b>草稿 (3)</b></summary>

| 工具 | 說明 |
|------|------|
| `list_drafts` | 列出草稿郵件 — 每筆帶 `subject` + 數字 `id`（[#276](https://github.com/PsychQuant/che-apple-mail-mcp/issues/276)，additive；可直接餵 `update_draft.draft_id` / `delete_email.id`）|
| `create_draft` | 建立草稿（支援附件） |
| `update_draft` | 更新既有草稿（upsert，[#276](https://github.com/PsychQuant/che-apple-mail-mcp/issues/276)）：以 `draft_id` 或精確 `subject_match` 定位 → 先建新（繼承 create_draft 資格與揭露）→ 再刪舊。刻意 create-then-delete + post-create receipt（失敗方向恆偏向保留草稿 — 最壞「可能並存」、絕不「兩頭空」）；0 或 >1 命中一律 refuse 列候選。重建後是新 id |

</details>

<details>
<summary><b>附件 (2)</b></summary>

| 工具 | 說明 |
|------|------|
| `list_attachments` | 列出郵件附件 |
| `save_attachment` | 儲存附件到磁碟 |

</details>

<details>
<summary><b>VIP (1)</b></summary>

| 工具 | 說明 |
|------|------|
| `list_vip_senders` | 列出 VIP 寄件者 |

</details>

<details>
<summary><b>規則 (5)</b></summary>

| 工具 | 說明 |
|------|------|
| `list_rules` | 列出郵件規則 |
| `get_rule_details` | 取得規則詳細資訊 |
| `create_rule` | 建立新規則 |
| `delete_rule` | 刪除規則 |
| `enable_rule` | 啟用/停用規則 |

</details>

<details>
<summary><b>簽名檔 (2)</b></summary>

| 工具 | 說明 |
|------|------|
| `list_signatures` | 列出郵件簽名檔 |
| `get_signature` | 取得簽名檔內容 |

</details>

<details>
<summary><b>SMTP (1)</b></summary>

| 工具 | 說明 |
|------|------|
| `list_smtp_servers` | 列出 SMTP 伺服器 |

</details>

<details>
<summary><b>同步 (2)</b></summary>

| 工具 | 說明 |
|------|------|
| `check_for_new_mail` | 檢查新郵件 |
| `synchronize_account` | 同步 IMAP 帳戶 |

</details>

<details>
<summary><b>批次 (4)</b></summary>

| 工具 | 說明 |
|------|------|
| `get_emails_batch` | 一次呼叫取得最多 50 封郵件（逐項錯誤回報） |
| `list_attachments_batch` | 一次列出最多 50 封郵件的附件 |
| `batch_export_emails_markdown` | 伺服器端批次匯出逐字 markdown + 附件（凍結 frontmatter、manifest；同 output_dir 併發序列化 — [#193](https://github.com/PsychQuant/che-apple-mail-mcp/issues/193) / [#236](https://github.com/PsychQuant/che-apple-mail-mcp/issues/236)） |
| `export_emails_markdown` | **已棄用** — 改名為 `batch_export_emails_markdown`（[#233](https://github.com/PsychQuant/che-apple-mail-mcp/issues/233)）；alias 不早於 v3.0 移除 |

</details>

<details>
<summary><b>工具程式 (4)</b></summary>

| 工具 | 說明 |
|------|------|
| `extract_name_from_address` | 從郵件地址擷取名稱 |
| `extract_address` | 從完整地址擷取郵件地址 |
| `get_mail_app_info` | 取得 Mail.app 資訊 |
| `import_mailbox` | 從檔案匯入信箱 |

</details>

<details>
<summary><b>診斷 (4)</b></summary>

| 工具 | 說明 |
|------|------|
| `check_fda` | 檢查「完整磁碟取用權限」狀態，並讓 server 立刻重試開啟自己的 index reader；回報 server 實際的 SQLite 快速路徑狀態（已開啟／剛恢復／仍不可用） |
| `check_accessibility` | 檢查「輔助使用」權限（wrapper-free 撰寫／回覆 GUI 路徑） |
| `check_automation` | 檢查「自動化」權限（對 Mail 的 Apple Events）— 非觸發式 probe、四態各配補救指引（#293）；binary 自持授權、osascript 可用 ≠ binary 已授權（#288） |
| `get_mail_log_events` | 唯讀查詢 Mail 自己的 unified log，找出事件鏈在哪一步斷掉（例如：草稿存檔 → 進佇列 → 通知引擎 → IMAP `APPENDUID` 回條，[#465](https://github.com/PsychQuant/che-apple-mail-mcp/issues/465)）。`detail=brief`（預設）只回靜態事件模板、整數參數，以及 `[帳號 - 信箱]` 形式那幾行的帳號代號，只要模板是編譯期字串（Mail 自己的都是），就不含帳號名稱、主旨或 Message-ID；`detail=detailed` 另附原始訊息，**內含帳號識別資訊與來信內容，不要貼進公開 issue**。窗口上限 60 分鐘，時間必須帶 UTC 偏移；續查用 `since=next_start`、`offset=next_offset` 加同一個 `until` 與 `events`。`events` 只保留 `event` 與所給名稱完全相等的事件：可以是模板、`imap.append_uid_received` 或 `<template withheld>`（被收回的模板不能用原文選取，也沒有子字串比對），簡短與詳細模式都可用；回應不回傳這些值，只回報 `event_filter_count`（[#466](https://github.com/PsychQuant/che-apple-mail-mcp/issues/466)）。查不到任何事件不代表動作沒發生。同時最多兩次讀取，第三次回 `status: unavailable`、`reason: busy` 且不啟動讀取（[#467](https://github.com/PsychQuant/che-apple-mail-mcp/issues/467)）。僅在 macOS 27.2／Mail 16.0 驗證過；需要 admin 群組的使用者 |

</details>

### 回傳結構：`search_emails` / `list_emails`

兩個工具回傳的是**信封物件（envelope）** `{ results, returned, limit, truncated }`，**不是**裸陣列（自 [v2.14.0](CHANGELOG.md)、[#204](https://github.com/PsychQuant/che-apple-mail-mcp/issues/204) 起變更）。從 `.results` 讀取符合的郵件：

| 欄位 | 意義 |
|------|------|
| `results` | 結果物件陣列（每個物件的欄位與信封化之前相同）。`search_emails` 的物件含 `id`、`subject`、`sender`、`date_received`、`account_name`、`mailbox`、`to`，以及可解析帳號 UUID 時的 `account_id`；`list_emails` 的物件含 `id`、`subject`、`sender`。 |
| `returned` | `results` 中的物件數量 |
| `limit` | 此次查詢實際套用的 `limit` |
| `truncated` | 當尚有未回傳的結果時為 `true`——**調高 `limit` 或縮小查詢範圍**以取得其餘結果（SQLite 快速路徑為確定判斷，AppleScript 後備路徑為盡力而為的啟發式，見下） |

在 SQLite 快速路徑上 `truncated` 是**確定的**（內部會多抓 `limit + 1` 筆）；在 AppleScript 後備路徑上則是盡力而為的 `returned == limit` 啟發式判斷。任何「列舉 → 批次處理」的消費端，在假設已取得完整結果集之前都應先檢查 `truncated`。

---

## 安裝方式

> **請先看[快速開始](#快速開始)** —— 安裝 plugin 才是受支援的路徑，會一併帶進
> 指令、安全規則、staleness hook 與簽章過的 binary。以下是**進階／開發**路線：
> 只註冊 MCP server，是嚴格更小的安裝（少了什麼見上方對照表，執行期不會有訊號）。

### 系統需求

- macOS 26.0+（macOS 13–15 請停在 v4.x）
- Xcode 命令列工具
- Apple Mail 已設定至少一個帳戶

### 步驟 1：編譯

```bash
git clone https://github.com/PsychQuant/che-apple-mail-mcp.git
cd che-apple-mail-mcp
swift build -c release
```

### 步驟 2：設定

#### Claude Desktop

編輯 `~/Library/Application Support/Claude/claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "che-apple-mail-mcp": {
      "command": "/完整路徑/che-apple-mail-mcp/.build/release/CheAppleMailMCP"
    }
  }
}
```

#### Claude Code (CLI)

```bash
# 複製到 ~/bin 並註冊
# --scope user    : 跨所有專案可用（存在 ~/.claude.json）
# --transport stdio: 本地 binary 執行，透過 stdin/stdout
# --              : 分隔 claude 選項和實際執行的命令
mkdir -p ~/bin
cp .build/release/CheAppleMailMCP ~/bin/
claude mcp add --scope user --transport stdio che-apple-mail-mcp -- ~/bin/CheAppleMailMCP
```

### 步驟 3：授予權限

最快的方式是設定視窗：顯示 Full Disk Access / Automation / Accessibility 的即時
狀態，授權當下就會翻成 Ready，並直接帶你到對的系統設定頁面。

```bash
~/bin/CheAppleMailMCP --setup
```

若要手動處理：

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
```

1. 找到 **CheAppleMailMCP** 並啟用 **Mail.app** 的權限
2. 如果使用 Claude Code，也要加入 **Terminal** 或 **iTerm**

### 步驟 4：重新啟動 Claude

```bash
# Claude Desktop
osascript -e 'quit app "Claude"' && sleep 2 && open -a "Claude"

# Claude Code - 開啟新的 session
claude
```

---

## 使用範例

### 自然語言（Claude Desktop）

```
「列出我所有的郵件帳戶」
「顯示 Gmail 收件匣的未讀郵件」
「搜尋關於『季度報告』的郵件」
「寄一封郵件給 john@example.com 討論會議事項」
「把重要郵件標記為紅色旗標」
「建立一個規則把電子報移到資料夾」
```

### 直接呼叫工具（Claude Code）

```
「用 list_accounts 顯示我的帳戶」
「用 search_emails 搜尋包含『發票』的郵件」
「用 set_flag_color 把郵件 ID 12345 標記為藍色」
「用 check_for_new_mail 重新整理」
```

---

## 旗標與背景顏色

### 旗標顏色（`set_flag_color`）

| 索引 | 顏色 |
|------|------|
| 0 | 紅色 |
| 1 | 橘色 |
| 2 | 黃色 |
| 3 | 綠色 |
| 4 | 藍色 |
| 5 | 紫色 |
| 6 | 灰色 |
| -1 | 清除 |

### 背景顏色（`set_background_color`）

`blue`, `gray`, `green`, `none`, `orange`, `purple`, `red`, `yellow`

---

## 直接傳送（send_draft、append_draft）

> **尚未對真實郵件伺服器跑過。** 在結果記到 [#742](https://github.com/PsychQuant/che-apple-mail-mcp/issues/742)
> 之前，每一種結果都當成未經驗證。

`send_draft` 經 SMTP 寄出伺服器草稿匣裡已有的一封草稿，不經 Mail（[#729](https://github.com/PsychQuant/che-apple-mail-mcp/issues/729)）。
它不寫任何內容：送出的就是伺服器存的那份草稿，去掉 `Bcc` 欄位；收件人取自 To、Cc、Bcc。帶 `X-Uniform-Type-Identifier: com.apple.mail-draft`
（Mail 存草稿時寫的標記）的草稿一律拒絕（[#745](https://github.com/PsychQuant/che-apple-mail-mcp/issues/745)）：Mail 用一種
寄出時會重組的版面存這類草稿（比對過的草稿是空的純文字段、內文在 HTML、草稿專用標頭），而這個工具原樣送出草稿。只檢查這個標記，
不檢查 MIME 結構。請用 `append_draft` 建草稿，或在 Mail 裡寄。只限
`~/.claude/.mail/direct-transport.json` 列出的帳號；其他帳號一律拒絕，也不改走 Mail。

`append_draft`（[#744](https://github.com/PsychQuant/che-apple-mail-mcp/issues/744)）經 IMAP 在同一批帳號的草稿匣建立一封新的
純文字草稿，同樣不經 Mail，也**尚未對真實郵件伺服器跑過**。它接受 `to`、`cc`、`bcc`（純位址，合計至少一個）、`subject`、`body`
與選填的 `from_name`，內容由工具自己組：單一 `text/plain`（UTF-8）、新的 Message-ID。這不是 Mail 自己存草稿的版面，所以
`send_draft` 可以把它原樣送出（Mail 存的草稿原樣送出會有什麼問題，見
[#745](https://github.com/PsychQuant/che-apple-mail-mcp/issues/745)）。結果是 `appended`、`not_appended`（伺服器拒絕，或在 APPEND 送出之前
連線、登入或找草稿匣就失敗）或 `unknown`；`unknown` 之後工具不重試。呼叫不會去重：兩次呼叫都存進去了，就有兩封。它回傳 `message_id`，`send_draft` 可以用它選草稿，所以建草稿與寄出都能在
Mail 關著時完成。

### 設定

1. 寫 `~/.claude/.mail/direct-transport.json`。每個欄位都必填，不認得的欄位會被拒絕。

   ```json
   {"accounts": [{
     "account_id": "<list_accounts 回報的 Mail 帳號 UUID>",
     "address": "you@icloud.com",
     "smtp": {"host": "smtp.mail.me.com", "port": 587},
     "imap": {"host": "imap.mail.me.com", "port": 993},
     "sent_copy": "append",
     "allowed_from": []
   }]}
   ```

   `sent_copy` 為 `append` 表示由工具把寄出的副本存進伺服器的寄件備份；為 `provider` 表示供應商自己會存。
   `allowed_from` 列出這個帳號可以用來寄信的其他位址。
2. 在終端機執行 binary，把密碼（iCloud 用 App 專用密碼）存進伺服器自己的 keychain 項目。密碼從標準輸入讀、
   不顯示，也不會印出：

   ```bash
   ~/bin/CheAppleMailMCP --direct-transport-set-credential you@icloud.com
   ```

   項目的 service 是 `che-apple-mail-mcp.direct-transport`。沒有任何 MCP 工具能建立、修改或讀出它，伺服器也
   不讀 Mail 的密碼。登入時以完整的 `address` 當使用者名稱。

兩條連線在送出密碼之前都先建立 TLS：連接埠 465 與 993 用 implicit TLS，其他連接埠一律要求 STARTTLS；
憑證要驗證，TLS 版本至少 1.2。

### 結果

| `outcome` | 意思 | 怎麼處理 |
|---|---|---|
| `submitted` | 伺服器接受了這封信。`sent_copy` 與 `draft_removal` 回報 `done`、`pending` 或 `skipped` | `pending` 的階段，用同一份草稿再呼叫一次 `send_draft` 就會補做，不會再送一次 |
| `not_sent` | 伺服器接受之前就被拒絕 | 依回覆修正後再呼叫 |
| `unknown` | 無法確定伺服器有沒有收下（例如信交出去之後連線中斷）；工具不會重試 | 去收件人的信或寄件備份確認。確定沒寄出，才執行 `--direct-transport-forget '<message-id>'`（要加引號，否則 zsh 會把角括號當成重導向）後再呼叫 |

每次提交都以 Message-ID 記在 `~/.claude/.mail/direct-transport-sent.json`，同一份草稿不會送兩次：狀態不明的紀錄
只能用命令列模式清除（有 `send_draft` 正在執行時不清），已提交的紀錄不能清除。一次只執行一個 `send_draft`。補做
`pending` 的階段，只在同一個帳號、而且伺服器上的草稿與提交時逐位元組相同時才做。只有提交時才連 SMTP 伺服器。Mail 的本機索引不會改，等 Mail 下次同步才跟上。

## 疑難排解

| 問題 | 解決方法 |
|------|----------|
| Server disconnected | 重新編譯 `swift build -c release` |
| 不允許傳送 Apple 事件 | 在系統設定 > 自動化 中新增權限 |
| Mail.app 沒有回應 | 確認 Mail.app 正在執行且已設定帳戶 |
| 指令逾時 | 大型信箱需要較長時間；嘗試更精確的搜尋 |

---

## 技術細節

- **框架**：[MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) v0.10.0
- **自動化**：透過 `NSAppleScript` 執行 AppleScript
- **傳輸**：stdio
- **平台**：macOS 26.0+（Tahoe 及更新版本）；macOS 13–15 停在 v4.x

---

## 貢獻

歡迎貢獻！請隨時提交 Pull Request。

---

## 授權

MIT License - 詳見 [LICENSE](LICENSE)。

---

## 作者

由 **鄭澈** ([@kiki830621](https://github.com/kiki830621)) 建立

如果覺得有用，請給個 Star 支持一下！
