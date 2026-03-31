# che-apple-mail-mcp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![MCP](https://img.shields.io/badge/MCP-Compatible-green.svg)](https://modelcontextprotocol.io/)

**最完整的 Apple Mail MCP 伺服器** - 44 個工具，SQLite 驅動的毫秒級搜尋，支援 25 萬封以上郵件。

[English](README.md) | [繁體中文](README_zh-TW.md)

---

## 為什麼選擇 che-apple-mail-mcp？

| 功能 | 其他 MCP | che-apple-mail-mcp |
|------|----------|-------------------|
| 工具總數 | ~20 | **44** |
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

```bash
# 複製並編譯
git clone https://github.com/kiki830621/che-apple-mail-mcp.git
cd che-apple-mail-mcp
swift build -c release

# 複製到 ~/bin 並加入 Claude Code
# --scope user    : 跨所有專案可用（存在 ~/.claude.json）
# --transport stdio: 本地 binary 執行，透過 stdin/stdout
# --              : 分隔 claude 選項和實際執行的命令
mkdir -p ~/bin
cp .build/release/CheAppleMailMCP ~/bin/
claude mcp add --scope user --transport stdio che-apple-mail-mcp -- ~/bin/CheAppleMailMCP
```

> **💡 提示：** 請將 binary 安裝到本機目錄如 `~/bin/`。避免放在雲端同步資料夾（Dropbox、iCloud、OneDrive），否則檔案同步可能造成 MCP 連線逾時。

然後在 **系統設定 > 隱私權與安全性 > 自動化** 中授予權限。

---

## 全部 44 個工具

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
<summary><b>草稿 (2)</b></summary>

| 工具 | 說明 |
|------|------|
| `list_drafts` | 列出草稿郵件 |
| `create_draft` | 建立草稿（支援附件） |

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
<summary><b>工具程式 (4)</b></summary>

| 工具 | 說明 |
|------|------|
| `extract_name_from_address` | 從郵件地址擷取名稱 |
| `extract_address` | 從完整地址擷取郵件地址 |
| `get_mail_app_info` | 取得 Mail.app 資訊 |
| `import_mailbox` | 從檔案匯入信箱 |

</details>

---

## 安裝方式

### 系統需求

- macOS 13.0+
- Xcode 命令列工具
- Apple Mail 已設定至少一個帳戶

### 步驟 1：編譯

```bash
git clone https://github.com/kiki830621/che-apple-mail-mcp.git
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
