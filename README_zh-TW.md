# che-apple-mail-mcp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![MCP](https://img.shields.io/badge/MCP-Compatible-green.svg)](https://modelcontextprotocol.io/)

**最完整的 Apple Mail MCP 伺服器** - 53 個工具，SQLite 驅動的毫秒級搜尋，支援 25 萬封以上郵件。

[English](README.md) | [繁體中文](README_zh-TW.md)

---

## 為什麼選擇 che-apple-mail-mcp？

| 功能 | 其他 MCP | che-apple-mail-mcp |
|------|----------|-------------------|
| 工具總數 | ~20 | **53** |
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
| 全部 53 個 MCP 工具 | ✅ 有 |
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

## 全部 53 個工具

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
<summary><b>撰寫 (5)</b></summary>

| 工具 | 說明 |
|------|------|
| `compose_email` | 撰寫新郵件（支援附件） |
| `reply_email` | 回覆郵件 |
| `forward_email` | 轉寄郵件 |
| `redirect_email` | 重導向郵件（保留原始寄件者） |
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
<summary><b>診斷 (3)</b></summary>

| 工具 | 說明 |
|------|------|
| `check_fda` | 檢查「完整磁碟取用權限」狀態（SQLite 快速路徑可用性） |
| `check_accessibility` | 檢查「輔助使用」權限（wrapper-free 撰寫／回覆 GUI 路徑） |
| `check_automation` | 檢查「自動化」權限（對 Mail 的 Apple Events）— 非觸發式 probe、四態各配補救指引（#293）；binary 自持授權、osascript 可用 ≠ binary 已授權（#288） |

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

- macOS 13.0+
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
- **平台**：macOS 13.0+（Ventura 及更新版本）

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
