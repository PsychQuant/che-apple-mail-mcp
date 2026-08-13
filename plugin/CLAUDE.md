# che-apple-mail-mcp

Apple Mail MCP server for macOS,加上 Foresay-derived confirmation protocol + IDD-derived task enforcement。

## 鐵律:Step 0 Bootstrap Stage Task List(v2.9.0+)

**`/archive-mail` 與 `confirmation-protocol` skill 的第一個動作必須是 `TaskCreate`**,把該 stage 的所有 execution sub-steps 建成 harness-level todo list。完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

學自 IDD plugin 的 enforcement pattern。為什麼:

- v2.7.0 加 confirmation-protocol skill,v2.8.0 加 namespace migration,但 spec-level 的「應該 confirm / 應該掃 false positive」依賴 Claude 讀 markdown 後自願執行
- 歷史 incident:2026-05-01 archive 陳老師信件,265250 false positive 漏網 → spec 有寫但被跳過
- TaskCreate 把每個 phase 變成 UI 可見的 binary state,跳過會留下 incomplete task 顯眼

兩處強制 bootstrap:
- `commands/archive-mail.md` Step 0 → 10 個 stage tasks (resolve_filter_and_paths / phase1_disambiguation / load_indices_and_config / search_emails / filter_and_scan_false_positives / phase2_3_preview_and_confirm / fetch_and_write_markdown / download_and_classify_attachments / update_indices / report_and_audit)
- `skills/confirmation-protocol/SKILL.md` → 4 個 phase tasks (disambiguation / search_preview / operation_confirmation / execute_or_iterate)

可 skip 的 phase(明確 filter 跳 Phase 1)也要 `TaskUpdate completed` + 在 description append skip 原因,不可只是不做。

## Components

### MCP Server
- **mail** ← `bin/che-apple-mail-mcp-wrapper.sh`(Swift binary)
- 提供 44+ tools 操作 Apple Mail.app:list/search/get/compose/move/delete/attachment

### Commands
- `/archive-mail` — 歸檔指定聯絡人的郵件到 Markdown(v2.7.0+ 加入 confirmation phases、v2.8.0+ 用 `.claude/.mail/` namespace)
- `/archive-mail-view` — 從 `threads.json` 生成 thread 聚合視圖
- `/archive-mail-rebuild-threads` — 從 per-email md 重建 thread index
- `/archive-mail-migrate`(v2.8.0+)— 一次性把舊 archive 的 indices + config 搬到 `.claude/.mail/` namespace

### Skills(v2.7.0+ 新增)
- `confirmation-protocol` — Foresay-style confirmation workflow,在執行前 show preview 讓 user confirm/correct
- `email-search-disambiguation` — 處理模糊 filter(中文人名、相對時間、通用 scope)
- `bulk-operation-preview` — ≥ 5 封 emails 的 preview format,含 false-positive flagging

### Rules(v2.7.0+ 新增)
- `confirmation-triggers.md` — 何時必 confirm、何時可 skip
- `false-positive-detection.md` — Search 結果中偵測 sibling activity / CC pollution / subject collision
- `compose-wrapper-free.md`(v2.43.0 匯入)— **正式信件 cite-block 紀律(CRITICAL)**:`compose_email`/`create_draft` 的 wrapper-free eligibility、`[legacy path — …]` 揭露義務、自訂寄件人/人名收件人/附件 recipes、TCC fallback ladder(-1743 時走 `open_mailto`,絕不靜默落到 wrapped body)。Canonical 版在 server repo 的 `.claude/rules/`,此為同步副本

## 設計哲學

### Foresay Confirmation Protocol

借鑑 [Foresay](https://github.com/kiki830621/foresay) 的核心 insight:

> AI 不直接執行,先 show 結構化的「我理解你要的是這樣」讓 user confirm/correct/reject,achieve consensus 後才執行。

原始 nsql 設計給 SQL/data query;這裡 adapt 到 Apple Mail。觸發 confirmation 的 4 個常見情境:

1. **Filter 模糊**:「陳老師」、「最近的信」、「VIP 寄來的」 → disambiguation
2. **Bulk operation**:search 結果 ≥ 5 封 → preview + false-positive flagging
3. **Destructive**:delete_email、empty Trash → operation confirmation
4. **Compose 寄出**:compose_email、reply_email → 信件 preview

### 為什麼這個 protocol 重要(real case)

2026-05-01 archive 陳老師信件時,直接 search → fetch 19 封 → 寫 markdown,事後發現 265250 是 false positive(寄給 scchen 不是 cchen),又走一輪 rm + index 修復。

如果有 confirmation skill,Phase 2 (search preview) 會 flag 這封並讓 user 排除,完全 prevent false-positive round trip。從 v2.7.0 開始,archive-mail 預設套用這個 protocol。

## 4-Phase Confirmation Workflow

```
user request
  │
  ▼
Phase 1: Disambiguation
  └─ 模糊 filter → 列出候選讓 user 選
  └─ 由 email-search-disambiguation skill 負責
  │
  ▼
Phase 2: Search Preview
  └─ 展示 search 結果(thread 分布)
  └─ Flag false-positive 候選
  └─ 由 bulk-operation-preview skill 負責
  │
  ▼
Phase 3: Operation Confirmation
  └─ 展示 side-effect scope(N files written, K attachments, etc.)
  └─ Destructive op 加警告
  │
  ▼
Phase 4: Execute or Iterate
  └─ User 確認 → 執行
  └─ User 修改 → 回 Phase 1/2/3
  └─ User 拒絕 → abort
```

## Skip confirmation 的條件

可以直接執行(skip protocol):

- 明確 Message-ID 的 read-only 操作
- 單封 mark_read / unflag
- 純 search/list(沒 side effect)
- User 說「直接做,不要問」

詳見 `rules/confirmation-triggers.md`。

## Use Cases

### Case 1: 完整流程(filter 模糊 + bulk + read-only)

```
user: 把陳老師有關的信都歸檔

AI [Phase 1]: 「陳老師」可能對應到 cchen / scchen / 其他?
user: cchen
AI [Phase 2]: 找到 19 封,7 個 threads。⚠ 1 個是 sibling activity 不該歸入。要排除嗎?
user: 排除
AI [Phase 3]: 我將寫 18 個 markdown + 下載 1 個附件 + 寫 2 個 index。確認?
user: 對
AI [Phase 4]: [執行]
```

### Case 2: 明確 filter(skip Phase 1)

```
user: archive cchen@stat.sinica.edu.tw 過去一週

AI [skip Phase 1]: filter 明確,跳過 disambiguation
AI [Phase 2]: 找到 3 封,沒 false positive。
AI [Phase 3]: 寫 3 個 markdown。確認?
user: 對
AI [Phase 4]: [執行]
```

### Case 3: Destructive(必 Phase 3)

```
user: 把 spam@example.com 的信全部刪掉

AI [Phase 2]: 找到 247 封 spam emails。沒 false positive。
AI [Phase 3]:
   DELETE on Mail
   with sender = "spam@example.com"
   affecting 247 emails
   ⚠ 進 Trash 後 30 天清除,可在那之前 undo
   確認?
user: 確認
AI [Phase 4]: [執行]
```

### Case 4: Read-only single op(完全 skip)

```
user: get_email id=12345

AI: [直接執行,沒 confirmation]
```

## Configuration

> **路徑遷移**:v2.7.0 ↓ 用 `.claude/emails.md`,v2.8.0+ 改用 `.claude/.mail/config.md`(auto-migrate),**v2.16.0+ 改用 `.claude/.mail/config.yaml`** 副檔名(silent rename per #47;legacy `.md` 仍 fallback,v3.0 移除)。下述 schema 三者通用。

### `.claude/.mail/config.yaml` Schema (v2.16.0+ #47)

> v2.15.0 ↓ 路徑為 `.claude/.mail/config.md`(legacy),首次跑 `/archive-mail` 或 `/archive-mail-migrate` 自動 rename。內容格式不變。

YAML frontmatter,空白 body。所有欄位可選,未填走 default。

```yaml
---
filters:                           # 預設 filter 清單(零參數模式讀此)
  - cchen                          #   string:可以是 email、email prefix、display name alias
  - coco891017                     #   match logic:Swift-side substring + Phase 1 disambiguation

participant_aliases:               # 模糊人名 → 標準 email 對應表
  "陳老師": cchen@stat.sinica.edu.tw
  "林助理": coco891017@webmail.stat.sinica.edu.tw

subject_keywords_strict: true      # bool, default false。true = subject-only match 不算 hit;
                                   # 防止「履歷」這種 generic 關鍵字汙染 result

enrichment: none                   # v2.13.0+: 'none'(預設,簡單 template) | 'summary+todos'(AI 摘要 + 待辦)

dedup_strategy: index              # v2.14.0+: 'index'(預設) | 'last_archived' | 'both'
                                   #   index = 用 .email_index.json (current default)
                                   #   last_archived = skip index,以 last_archived 日期作 date_from
                                   #   both = 兩者皆用 (Message-ID 為主, date 為輔)

output_dir: communications/emails  # string,default "communications/emails"。
                                   # archive markdown 寫入路徑(相對 cwd)

attachments_dir: correspondence/attachments  # string,default 同上格式。附件根目錄

attachment_routing:                # 附件依副檔名分流
  data_extensions:                 #   list[string]:被視為「資料」的副檔名
    - csv
    - sav
    - xlsx
    - rds
  data_dir: data/raw               #   data 副檔名導到此(覆蓋 attachments_dir)
  documents_dir: correspondence/attachments  # 其他副檔名導到此

exclude_mailboxes:                 # list[string],default []。完全跳過的 mailbox 名稱
  - Junk
  - Trash
  - Drafts

last_archived:                     # ISO-8601 timestamp;archive-mail 會自動更新
  2026-05-01T13:30:00+08:00        # 用於 incremental archive(只抓此後的信);搭配 dedup_strategy='last_archived' 必填
---
```

### Field 互動規則

- `filters` + 命令列參數同時指定 → 命令列覆蓋
- `participant_aliases` 在 Phase 1 disambiguation 優先 match
- `subject_keywords_strict=true` 時 sender / recipient match 仍 hit;只阻擋「only subject contains keyword」的 lone match
- `attachment_routing.data_extensions` ∩ 真實附件 → 走 `data_dir`,其他走 `documents_dir`(若未設 `data_extensions` 則全部走 `documents_dir`)
- `last_archived` 不存在 → 全量 archive;存在 → 只抓 received-date > last_archived 的 emails

## 帳號名稱陷阱:EWS URL vs Display Name

Apple Mail.app(via AppleScript)在 `account` property 上**同時用兩種識別**而沒一致對應:

| 場景 | 回傳值 | 例 |
|------|--------|----|
| `list_accounts` | display name | `"Sinica Mail"` |
| Email object 的 `account` field | EWS URL | `"https://owa.sinica.edu.tw/EWS/Exchange.asmx"` |
| Filter / search by account | 接受 display name | `"Sinica Mail"` |
| `set account of email to X` | 需 display name | `"Sinica Mail"` |

### 為什麼會踩雷

Search 結果的 email 可能來自 IMAP 帳號(display name)或 Exchange/EWS 帳號(URL)。直接拿 email.account 字串去 `move_email account="..."` 會在 EWS 帳號失敗 — 因為 set account 接受 display name 不接受 URL。

### 正確做法

1. 永遠先 `list_accounts` 取 display name 清單
2. 對 EWS-style 帳號,維護 URL → display name mapping(plugin 內已有 `account_normalize` helper)
3. 對 user 顯示一律用 display name

### 相關 issue

- #15 — display-name vs internal-name 混用導致 archive-mail 在多帳號環境噴錯(已 close)
- 本陷阱由 #15 提煉成 plugin 內建 normalization layer

## File Layout — `.claude/.mail/` Namespace(v2.8.0+)

學 IDD `.claude/.idd/` 的 namespace 收斂 pattern。**Config + state 集中,archive markdown 保持原位**:

```
{cwd}/
├── .claude/.mail/                              ← namespace root
│   ├── config.yaml                             ← v2.16.0+;legacy v2.7.0 ↓ 路徑為 .claude/emails.md;v2.8.0–v2.15.0 為 config.md
│   └── state/
│       └── archives/
│           └── {slug}/                          ← per-archive-target,slug = output_dir.replace("/", "-")
│               ├── email_index.json            ← Message-ID 去重
│               ├── threads.json                ← thread 關係索引
│               └── threads.json.bak.*          ← rebuild-threads 的備份
├── communications/emails/                      ← archive markdown 目的地(不變)
│   ├── 2026-01-13_xxx.md                       ← archive 結果(user-visible)
│   └── ...
└── correspondence/attachments/                 ← attachments(不變)
    └── 2026-01-13_xxx/
```

### 為什麼這樣分

| 路徑 | 性質 | 為什麼 |
|------|------|--------|
| `.claude/.mail/config.yaml` | Plugin config(v2.16.0+;legacy `.md` 仍 fallback) | User 改的 YAML config,跟工作流綁定 |
| `.claude/.mail/state/archives/{slug}/` | Plugin state | 自動產生的索引,user 不手動編輯 |
| `{output_dir}/` | User-visible 歸檔結果 | User 主動 ls 找的 archive markdown |
| `{attachments_dir}/` | User-visible 附件 | 同上 |

### Auto-migrate(從 v2.7.0 ↓ 升級)

v2.8.0+ 的 `archive-mail` / `view` / `rebuild-threads` **每次跑都會 silent auto-migrate**:若新位置不存在但舊位置有 file,直接 mv 過去並提示「🔄 Migrated X → Y」。

如果想一次 batch migrate 所有 archive targets,跑 `/archive-mail-migrate`(支援 `--dry-run` 預覽)。

## Version History

- **v2.9.0**(2026-05-01)— **Task enforcement**:學 IDD 的 Step 0 Bootstrap Stage Task List 鐵律。`/archive-mail` 開工前強制 `TaskCreate` 10 個 stage tasks,`confirmation-protocol` skill 強制 4 個 phase tasks,完成立即 `TaskUpdate`,靜默 skip = 違規。把 v2.7.0 spec-level confirmation 升級到 enforce-level
- **v2.8.0**(2026-05-01)— **`.claude/.mail/` namespace**:學 IDD 的 `.claude/.idd/` 收斂 config + state。新增 `/archive-mail-migrate`。archive-mail / view / rebuild-threads 都加 auto-migrate。Backward compatible:legacy paths 自動 detect 並搬遷
- **v2.7.0**(2026-05-01)— **NSQL confirmation protocol**:加 3 skills + 2 rules + CLAUDE.md。archive-mail 預設套用 4-phase confirmation workflow。Backward compatible:精確 filter 仍可直接執行
- v2.6.0 — archive-mail YAML frontmatter + .threads.json + view/rebuild commands
- v2.5.0 — composing tools format 參數
- v2.4.0 — search expansion + Coverage Audit
- v2.3.0 — attachment auto-download + 分流

## MCP Tool 命名 prefix

Claude Code 載入本 plugin 時,所有 MCP tool 都以 `mcp__plugin_che-apple-mail-mcp_mail__*` 為 prefix。例:

```
mcp__plugin_che-apple-mail-mcp_mail__list_accounts
mcp__plugin_che-apple-mail-mcp_mail__search_emails
mcp__plugin_che-apple-mail-mcp_mail__compose_email
mcp__plugin_che-apple-mail-mcp_mail__archive_email     ← 不存在,archive 走 /archive-mail command
```

### Prefix 拆解

| 段 | 意義 |
|----|------|
| `mcp__` | 固定前綴(Claude Code 區分 MCP tool vs built-in) |
| `plugin_` | tool 來自 plugin(非全 user-level MCP server) |
| `che-apple-mail-mcp` | plugin name(對應 `.claude-plugin/plugin.json` `name` field) |
| `_mail__` | MCP server 名稱(`.mcp.json` 裡的 server key) |
| `*` | tool 名稱(Swift binary 註冊的 tool name) |

### 用途

- 多 plugin 共存時不撞名(e.g. 別的 plugin 也叫 `list_accounts`)
- Allow-list 設定可整 plugin 一次准許 / 拒絕(`mcp__plugin_che-apple-mail-mcp_*`)
- Claude Code log 一眼看出 tool 來自哪個 plugin

### 相關文件

- Anthropic MCP plugin spec — https://code.claude.com/docs/en/plugins
- `.mcp.json` 裡 `mail` 那個 key 決定 prefix 中段(改名要同步改 wrapper)

## 相關

- `core/protocol.yaml` — Foresay Confirmation Protocol spec（https://github.com/kiki830621/foresay）
- `docs/concept.md` — Foresay whitepaper（同上 repo）
- `commands/archive-mail.md` — Archive workflow(含 confirmation phases)
