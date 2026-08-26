# che-apple-mail-mcp

macOS Apple Mail MCP server with native AppleScript integration.

## Features

- List accounts, mailboxes, and emails
- Search emails with UTF-8 support (Swift-layer filtering)
- Read, reply, forward emails
- Manage drafts, attachments, rules
- Flag, move, delete operations
- VIP senders and signatures

## Commands

### `/archive-mail` — 歸檔郵件到 Markdown

把指定聯絡人的 Apple Mail 郵件批次歸檔為 Markdown 檔案，自動去重。v2.7.0+ 預設套用 4-phase Foresay confirmation protocol（filter 模糊先 disambiguate、bulk 結果先 preview + flag false positives、destructive op 必 confirm），v2.9.0+ 強制 `TaskCreate` 10 個 stage tasks 確保每 phase 不被靜默 skip。

```bash
# Zero-arg mode (v2.12.0+, v2.16.0+ reads .yaml) — reads .claude/.mail/config.yaml
/archive-mail

# Explicit filter mode (always available)
/archive-mail some@example.com
/archive-mail some@example.com communications
```

版本沿革自 #396 起收斂於 [CHANGELOG.md](CHANGELOG.md)（shell 敘事單源）。

#### Workspace Patterns (v2.17.0+)

archive-mail 不假設一個 canonical layout——adapt 到 user 的既有 folder 配置。三種主要 pattern:

| Pattern | Folder shape | When detection picks it |
|---------|--------------|--------------------------|
| **Nested channel layout** | `<workspace>/communications/email/` | `communications/email/` 存在;為「multi-channel comms」(email + future chat / letters / etc.) 預留結構。Forward direction(per kiki830621/chchen-lab 2026-05-08+) |
| **Legacy correspondence layout** | `<workspace>/correspondence/emails/` | 上面不存在但 `correspondence/emails/` 存在。pre-v2.17 既有 user convention,detection 認得不需要 migrate |
| **Baseline default** | `<workspace>/communication/emails/` | 兩者皆無;archive-mail 自己建這個 dir 並使用 |

**Precedence**(高 → 低):

1. 命令列 `$ARGUMENTS[1]` (`/archive-mail <filter> <output_dir>`)
2. `${CONFIG_FILE}` (`.claude/.mail/config.yaml`) 的 `output_dir:` 欄位
3. **Workspace Layout Detection**(本節 v2.17.0+ 新增)
4. Baseline default `communication/emails`

**Pin convention via explicit config**:若想 lock 一個 layout(例如 `psychophysic_representations` 走 `correspondence/emails`),在 config 寫:

```yaml
# .claude/.mail/config.yaml
output_dir: correspondence/emails
filters:
  - someone@example.com
```

已 explicit-pin 的 workspace 行為不變;zero-config 且 `communications/email/` 與 `correspondence/emails/` 同時存在含 `*.md` 的 mid-migration workspace 會被 ambiguity guard flag,要求 explicit pin(避免半實作狀態的 dedup-index split-brain)。

**Symlink coexistence**(transitioned-project pattern):

```
chchen_lab/
└── communications/email/
    ├── 2026-05-09_subject.md       ← live archive (archive-mail 寫入)
    ├── 2026-05-08_subject.md       ← live archive
    └── application/                ← SYMLINK → ../../applications/completed/.../emails/
        ├── 2026-04-29_old.md       ← 19 historical md files (read-only,never written)
        └── ...
```

archive-mail v2.17.0+ 會:

1. **掃 symlink subdirectories**:`find -P "${output_dir}" -maxdepth 1 -type l`
2. **讀其下 markdown 的 `message_id:` YAML frontmatter**:`find -P "$symlink_dir/" -maxdepth 2 -name "*.md"` → `head -30` → `awk` extract
3. **併入 in-memory dedup set**:Step 4 dedup logic 排除既有 + extended 的 Message-ID 集合
4. **絕不寫入 symlink target**:read-only by contract

**Ambiguity guard**:當 `communications/email/` 與 `correspondence/emails/` **同時存在且都有 `*.md` 檔**(mid-migration 異常情境),archive-mail abort with explicit error,要求 pin `output_dir:` in config。Empty-dir-as-marker 不算 ambiguity(常見於剛建好新 layout、還沒第一次 archive 的 workspace)。

**Diagnose 與 verify 哪個 path 在用**:archive-mail 啟動會印 detection 結果:

- `🔍 Detected output_dir: communications/email (from layout probe)` ← Probe 1 hit
- `🔍 Detected output_dir: correspondence/emails (legacy layout probe)` ← Probe 2 hit
- `🔗 Extended dedup with N entries from sibling archives:` ← Step 2.1 dedup extension fired
- (silent) ← detection didn't fire because explicit config / `$ARGUMENTS[1]` won

詳細 detection algorithm + edge cases 見 [`commands/archive-mail.md`](commands/archive-mail.md) §Step 1 Workspace Layout Detection 與 §Step 2.1 Sibling-archive dedup extension。

每封 md 帶 YAML frontmatter（`message_id` / `thread_key` / `in_reply_to` / `date` / `sender` / `direction`），並同步維護 `email_index.json`（Message-ID 去重）與 `threads.json`（thread 關係索引），v2.8.0+ 收斂到 `.claude/.mail/state/archives/{slug}/`。

詳細 spec 見 [`commands/archive-mail.md`](commands/archive-mail.md)。完整 changelog 見 [`CHANGELOG.md`](CHANGELOG.md)。

### `/archive-mail-view` — 生成 thread 聚合視圖（v2.6.0+）

```bash
/archive-mail-view "SE manuscript 10xx-2025"
/archive-mail-view "SE manuscript" communications
```

讀 `threads.json` + per-email md，依時序聚合成一個 thread 視圖檔（存在 `.threads/` 子目錄）。視圖是 derived 資料，原始 md 不變，可重複生成。

### `/archive-mail-rebuild-threads` — 從 md 重建 thread 索引（v2.6.0+）

```bash
/archive-mail-rebuild-threads
/archive-mail-rebuild-threads communications
```

掃所有 md 的 YAML frontmatter 重建 `threads.json`。用在索引損壞、手動改過 thread_key、或舊 archive 升級後的 sanity check。

### `/archive-mail-migrate` — 收斂 indices + config 到 namespace（v2.8.0+）

```bash
/archive-mail-migrate --dry-run    # 預覽
/archive-mail-migrate              # 執行
```

把散在各個 archive directory 的 `.email_index.json`、`.threads.json` 以及 `.claude/emails.md` 集中搬到 `.claude/.mail/` namespace（學 IDD 的 `.claude/.idd/` pattern）。`/archive-mail`、`view`、`rebuild-threads` 也會 silent auto-migrate；這個 command 是想一次 batch migrate 所有 archive targets 時用。

## Skills (v2.7.0+)

3 個 skills 由 `/archive-mail` 內部觸發，也可被其他工作流引用：

- **`confirmation-protocol`** — Foresay-style 4-phase workflow（disambiguation → search preview → operation confirmation → execute or iterate）。v2.9.0+ Bootstrap 強制 `TaskCreate` 4 個 phase tasks，靜默 skip = 違規
- **`email-search-disambiguation`** — 處理模糊 filter（中文人名「陳老師」、相對時間「最近」、通用 scope「全部」），列候選讓 user 選定
- **`bulk-operation-preview`** — ≥ 5 封 emails 的 preview format，含 false-positive flagging（✓/⚠/⚠⚠/❓）

## File Layout — `.claude/.mail/` Namespace (v2.8.0+)

學 IDD `.claude/.idd/` 的 namespace 收斂 pattern。Config + state 集中，archive markdown 保持原位：

```
{cwd}/
├── .claude/.mail/                              ← namespace root
│   ├── config.yaml                             ← YAML(filters / aliases / attachment routing) — v2.16.0+;legacy .md fallback 至 v3.0
│   └── state/archives/{slug}/                  ← per-archive-target indices
│       ├── email_index.json                    ← Message-ID 去重
│       └── threads.json                        ← thread 關係索引
├── communications/emails/                      ← archive markdown 目的地（不變）
└── correspondence/attachments/                 ← attachments（不變）
```

從 v2.7.0 ↓ 升級會 silent auto-migrate（archive-mail / view / rebuild-threads 跑時都會 detect 舊位置並搬遷）。也可主動跑 `/archive-mail-migrate` 一次完成。

## Installation

### Option 1: From Release (Recommended)

```bash
# Download latest release
curl -L https://github.com/kiki830621/che-apple-mail-mcp/releases/latest/download/CheAppleMailMCP -o ~/bin/CheAppleMailMCP
chmod +x ~/bin/CheAppleMailMCP
```

### Option 2: Build from Source

```bash
cd /path/to/che-apple-mail-mcp
swift build -c release
cp .build/release/CheAppleMailMCP ~/bin/
```

## Usage Notes

### i18n Best Practices

This MCP follows internationalization best practices:

1. **Use `list_mailboxes` first** to discover available mailbox names for your locale
2. **Standard English names** (`INBOX`, `Drafts`, `Sent`) will try AppleScript system properties
3. **Localized names** (e.g., `收件匣`) should be used exactly as returned by `list_mailboxes`

### Example Workflow

```
# Step 1: Discover mailboxes
list_mailboxes(account="your@email.com")
# Returns: 收件匣, 草稿, 寄件備份, ...

# Step 2: Use exact name
search_emails(account="your@email.com", mailbox="收件匣", query="keyword")
```

## Permissions Required

- **Full Disk Access** or **Mail** permission in System Settings > Privacy & Security
- Grant access when prompted on first run

## Source Code

https://github.com/kiki830621/che-apple-mail-mcp

## Version History

版本沿革見 [CHANGELOG.md](CHANGELOG.md) —— #396 起為 shell 敘事的唯一 source（binary/server
沿革見 repo 根目錄的 `CHANGELOG.md`）。本節先前的逐版敘事已隨 #396 移除：它與 plugin.json
`description`、CHANGELOG 三處並行維護、必然漂移 —— 實證是移除當下本節同時掛著 v2.44.2 與
v2.19.6 兩個時代的斷裂敘事，而 `description` 開頭還停在 v2.43.0。
