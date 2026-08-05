---
description: 歸檔指定聯絡人的 Apple Mail 郵件到 Markdown 檔案
argument-hint: "[email-filter] [output-dir]  # 零參數時讀 .claude/.mail/config.yaml"
allowed-tools: mcp__plugin_che-apple-mail-mcp_mail__*, Bash(mkdir:*), Read, Write, Glob
---

# Archive Mail

歸檔指定聯絡人的郵件到 Markdown 檔案。

## 使用方式

```
/archive-mail                                    # 零參數(v2.12.0+;v2.16.0+ 讀 .claude/.mail/config.yaml,.md fallback)
/archive-mail user@example.com
/archive-mail user@example.com communication/emails
```

- 第一個參數(**v2.12.0+ 可選**):Email 過濾條件(寄件人或收件人包含此字串)
- 第二個參數(可選):輸出目錄,預設 `communication/emails`

#### 零參數模式

當 cwd 已有 `.claude/.mail/config.yaml`(v2.16.0+;舊 `.md` 仍 fallback,首次 invoke auto-migrate 為 `.yaml`)並設定 `filters` 時,可不帶任何參數呼叫;從 config 讀取:

| Field | 用途 |
|-------|------|
| `filters` | 多個 filter,作 OR-search 合併 corpus |
| `output_dir` | 覆寫 default `communication/emails` |
| `last_archived` | 給 search_emails 設 `date_from`(只抓此時點之後的信)|
| `exclude_mailboxes` | search 跳過(垃圾郵件 / 草稿等)|
| `sender_includes` | Layer 2 post-fetch: keep thread 若任一 message sender 含 substring(v2.20.0+, #84)|
| `sender_excludes` | Layer 2 post-fetch: drop thread 若任一 message sender 含 substring(v2.20.0+, #84)|
| `recipient_includes` | Layer 2 post-fetch: keep thread 若任一 message recipient 含 substring(v2.20.0+, #84)|
| `recipient_excludes` | Layer 2 post-fetch: drop thread 若任一 message recipient 含 substring(v2.20.0+, #84)|
| `subject_includes` | Layer 2 post-fetch: keep thread 若任一 message bare subject 含 substring(v2.20.0+, #76)|
| `subject_excludes` | Layer 2 post-fetch: drop thread 若任一 message bare subject 含 substring(v2.20.0+, #76)|
| `distributed_archives` | YAML 清單:分派去向的 archive 目錄(不限 symlink、不限在 `output_dir` 底下)。Step 2.1 把這些目錄的 `message_id` 併入 capture 層 dedup set,支援 capture-then-distribute 工作流(v2.38.0+, #285)|

兩層 corpus model:`filters` / `subject_keywords` / `exclude_mailboxes` 是 Layer 1 search-time(定義 corpus);6 個 `*_includes` / `*_excludes` 是 Layer 2 post-fetch refinement(thread-coherent narrowing,excludes-precedence on same axis,case-insensitive substring)。完整契約見 spec `openspec/specs/archive-mail-corpus-refinement/spec.md`。

命令列參數仍可覆寫 config(傳一個 filter 就只用該 filter,不讀 config 的 filters 清單)。詳細 schema 見 plugin CLAUDE.md。

## 執行步驟

### Step 0: Bootstrap Stage Task List(v2.9.0+ 鐵律,強制)

**在動任何事之前**先用 `TaskCreate` 為這個 stage 建 stage-level todo list，確保每個 sub-step 都被追蹤。學 IDD `idd-implement` 的 enforcement pattern。

```
TaskCreate(subject="resolve_filter_and_paths",
           description="Step 1 + 1.6: 解析 $ARGUMENTS → filter + output_dir. 計算 .claude/.mail/state/archives/{slug} 路徑。Auto-migrate legacy .email_index.json / .threads.json / .claude/emails.md。")

TaskCreate(subject="phase1_disambiguation",
           description="Step 1.5: 若 filter 模糊(中文人名「陳老師」/相對時間「最近」/通用 scope「全部」) → 列候選讓 user 選;明確 email/Message-ID/--no-confirm → skip。由 confirmation-protocol skill Phase 1 + email-search-disambiguation 處理。")

TaskCreate(subject="load_indices_and_config",
           description="Step 2: 從 ${INDEX_DIR}/ 讀 email_index.json + threads.json + ${CONFIG_FILE} 的 attachment_routing / subject_keywords / participant_aliases。")

TaskCreate(subject="search_emails",
           description="Step 3 + 3b + 3c + 3d: 對每個帳號跑 sender 搜尋 + Sent-scoped recipient 搜尋(寄出信,plugins#109) + subject_keywords 搜尋 + bare-subject thread expansion,四組結果套 mailbox 後過濾規則(統一 drop-set,勿裸 ==)後 Message-ID 去重 → corpus。注意 account_name 必須用 display name 不可用 ews:// URL。")

TaskCreate(subject="filter_and_scan_false_positives",
           description="Step 4 + 強制 false-positive scan(rules/false-positive-detection.md): 過濾出 Message-ID 不在索引的 emails → 待歸檔清單。對每個 thread 跑 flag_thread() → 標 ✓/⚠/⚠⚠/❓。Sibling activity / CC pollution / subject collision 三種 pattern 必須 check。")

TaskCreate(subject="phase2_3_preview_and_confirm",
           description="Step 4.5: 若待歸檔 ≥ 5 封 OR 有 ⚠⚠ flag OR destructive op → Phase 2 preview (thread breakdown + flags) + Phase 3 operation confirmation (file count + attachment size)。等 user 確認(a)/排除(b)/改 filter(c)/取消(d)。User skip 條件見 confirmation-triggers.md。")

TaskCreate(subject="fetch_and_write_markdown",
           description="Step 5: 主路徑 Step 5.0 — 待歸檔 ≥ 5 封且非 enriched → batch_export_emails_markdown 整個 corpus 一批伺服器端匯出(direction 由工具 per-email sender-identity 判定, binary v2.26.0+ mail#316; 帶 opts.filenames 保留命名慣例, 不帶 include_attachments), 留存 manifest 供 Step 8.5。Fallback Step 5.1 — 對每封 get_email(format='text', 用 display name) → 同 6-field frontmatter + body markdown, 檔名規則(YYYY-MM-DD_subject-hyphenated[-N].md, 截 50 graphemes) 寫到 ${output_dir}/。")

TaskCreate(subject="download_and_classify_attachments",
           description="Step 5.5: list_attachments → 用 classify() 分 data/document → save_attachment 到 data_dir / documents_dir/{email_stem}/。Markdown 插 Attachments: 區塊。回覆信無 byte 附件但引用原信附件 → cross-reference。")

TaskCreate(subject="update_indices",
           description="Step 5.7 + Step 6: 對每封新歸檔的信 append 到 ${THREADS_FILE} 的 thread_key entry (messages append, participants set, first/last_message, message_count)。把新 Message-ID + thread_key 加到 ${INDEX_FILE}。Append-only,不修改既有 entry。")

TaskCreate(subject="report_and_audit",
           description="Step 7 + 8: 輸出歸檔報告(新歸檔/跳過/thread 索引/附件分流)。執行 Coverage Audit (8a 附件完整性 + 8b thread 完整性 → search by bare_subject 比對 archived/total)。")

TaskCreate(subject="reconcile_index",
           description="Step 8.5(強制最終 gate,mail#261 + plugins#110): Phase 0 若本 run 有 batch manifest → 對每個 written item 三源合併(written_path/manifest message_id/4.5-preview date+subject/寫出 frontmatter thread_key)機械化補齊,零 heuristic;Phase 1 掃 ${output_dir} 頂層全部 *.md 的 frontmatter message_id → 每個都必須在 Phase-0 set 或 ${INDEX_FILE} keys 內,歷史孤兒就地補寫 canonical schema entry {file,date,subject,thread_key}(subject 從本文 Subject: 行 heuristic,僅 Phase 1)或列 unparseable;index 寫回走 temp+rename 原子寫入;last_updated bump 為 max(entry date,經 robust to_ymd 正規化——ISO 快篩+RFC822 parse,mail#275);repaired>0 → 跑 /archive-mail-rebuild-threads;輸出 Phase0/Phase1 reconcile 摘要。此 task 未 verified 前,整個 run 不得標示成功 — 靜默完成 = 違規。")
```

**完成每一步立即 `TaskUpdate → completed`。靜默完成 = 違規。**

中途若發現要分更多 sub-tasks(例如 Phase 2 preview 需要分批,或 attachment 下載失敗需要 retry),用 `TaskCreate` 補加。

**為什麼**:沒有 Stage TaskList 時,Claude 看 markdown spec 容易跳步驟(例如 false-positive scan 漏跑、Phase 2 preview 用「應該不需要」rationalize 掉)。Stage TaskList 把「跳過」變成顯眼的 incomplete task,user 在 UI 看得到。歷史上 2026-05-01 archive 陳老師信件就是因為沒跑 false-positive scan,265250 false positive 漏網,事後又花一輪 rm + index 修復。

### Step 1: 解析參數

從 `$ARGUMENTS` 取得:
- `filter`: 第一個參數(可選,**v2.12.0+ 零參數模式**)
- `output_dir`: 第二個參數;若未給且 `${CONFIG_FILE}` 也沒設,進 **Workspace Layout Detection**(v2.17.0+,見下方)決定;最終 fallback 為 `communication/emails`

#### Config parsing(always-on,v2.17.0+ #49)

不論 `$ARGUMENTS` 是空還是有內容,**只要 `${CONFIG_FILE}` 存在就先 parse**。理由:`/archive-mail <filter>`(只給第一個 arg)的 user 也應該尊重 config `output_dir:` pin,不能 silently fall through 到 detection。

> **Forward reference**:`${CONFIG_FILE}` 由 Step 1.6 計算(`.claude/.mail/config.yaml`,legacy `.md` fallback)。AI executor 整段 skill 讀完才開始執行,所以 forward-reference 在 markdown skill 慣例下 OK;若有人手動 copy bash 出來跑,先看 Step 1.6 的 `CONFIG_FILE` 賦值。

```bash
# Always parse config if file exists — independent of $ARGUMENTS state
CFG_OUTPUT_DIR=""
LAST_ARCHIVED=""
EXCLUDE_MBX=""
SENDER_INCLUDES=""
SENDER_EXCLUDES=""
RECIPIENT_INCLUDES=""
RECIPIENT_EXCLUDES=""
SUBJECT_INCLUDES=""
SUBJECT_EXCLUDES=""
DISTRIBUTED_ARCHIVES=""
if [ -f "${CONFIG_FILE}" ]; then
    # Parse YAML config (top-level scalars + sequences only)
    # 兼容 pure YAML(`.yaml` v2.16.0+)與 frontmatter-wrapped(`.md` legacy);awk pattern 對兩者皆 work
    # `---` 邊界(若 .md 用 frontmatter style)由 pattern 自然 skip(不 match `^[a-z_]+:`)
    CFG_OUTPUT_DIR=$(awk '/^output_dir:[ \t]*/{sub(/^output_dir:[ \t]*/,"");print;exit}' "${CONFIG_FILE}")
    LAST_ARCHIVED=$(awk '/^last_archived:[ \t]*/{sub(/^last_archived:[ \t]*/,"");print;exit}' "${CONFIG_FILE}")
    EXCLUDE_MBX=$(awk '/^exclude_mailboxes:/{flag=1;next} /^[a-z_]+:/{flag=0} flag && /^  - /{sub(/^  - /,"");print}' "${CONFIG_FILE}")

    # Layer 2 post-fetch corpus refinement (v2.20.0+, #76 + #84):
    # Six opt-in corpus-refinement fields. Same awk shape as exclude_mailboxes — multi-line `  - item` block-style only.
    # Full spec: openspec/specs/archive-mail-corpus-refinement/spec.md
    SENDER_INCLUDES=$(awk '/^sender_includes:/{flag=1;next} /^[a-z_]+:/{flag=0} flag && /^  - /{sub(/^  - /,"");print}' "${CONFIG_FILE}")
    SENDER_EXCLUDES=$(awk '/^sender_excludes:/{flag=1;next} /^[a-z_]+:/{flag=0} flag && /^  - /{sub(/^  - /,"");print}' "${CONFIG_FILE}")
    RECIPIENT_INCLUDES=$(awk '/^recipient_includes:/{flag=1;next} /^[a-z_]+:/{flag=0} flag && /^  - /{sub(/^  - /,"");print}' "${CONFIG_FILE}")
    RECIPIENT_EXCLUDES=$(awk '/^recipient_excludes:/{flag=1;next} /^[a-z_]+:/{flag=0} flag && /^  - /{sub(/^  - /,"");print}' "${CONFIG_FILE}")
    SUBJECT_INCLUDES=$(awk '/^subject_includes:/{flag=1;next} /^[a-z_]+:/{flag=0} flag && /^  - /{sub(/^  - /,"");print}' "${CONFIG_FILE}")
    SUBJECT_EXCLUDES=$(awk '/^subject_excludes:/{flag=1;next} /^[a-z_]+:/{flag=0} flag && /^  - /{sub(/^  - /,"");print}' "${CONFIG_FILE}")

    # v2.38.0+ (#285): distributed_archives — capture-then-distribute dedup.
    # Same block-style sequence awk as exclude_mailboxes. A list of distribution-
    # target archive dirs (NOT symlinks, NOT necessarily under output_dir) whose
    # message_id frontmatter Step 2.1 folds into the dedup set, so a capture-layer
    # run never re-pulls mail already distributed to a sub-project.
    DISTRIBUTED_ARCHIVES=$(awk '/^distributed_archives:/{flag=1;next} /^[a-z_]+:/{flag=0} flag && /^  - /{sub(/^  - /,"");print}' "${CONFIG_FILE}")

    # Validation: malformed refinement value aborts with explicit error (spec ADDED Requirement).
    # Sequence-form: `<field>:` on its own line, with `  - item` lines following → awk parser handles cleanly.
    # Inline scalar or non-empty inline list on the same line → refuse here, do not silently coerce.
    # Empty inline list `[]` and bare `<field>:` (no value) are both valid sequence forms.
    for _f in sender_includes sender_excludes recipient_includes recipient_excludes subject_includes subject_excludes; do
        _line=$(awk -v field="^${_f}:" '$0 ~ field {print; exit}' "${CONFIG_FILE}")
        if [ -n "$_line" ]; then
            _val=$(printf '%s' "$_line" | sed -E "s/^${_f}:[[:space:]]*//")
            if [ -n "$_val" ] && [ "$_val" != "[]" ]; then
                echo "Error: ${_f} must be a YAML multi-line block-style sequence of strings (\`${_f}:\` on its own line followed by indented \`  - item\` lines). Got inline value: ${_val}" >&2
                exit 1
            fi
        fi
    done

    # Strip empty entries from refinement lists per spec (sender_excludes: [""] ≡ sender_excludes: []).
    # The awk above prints raw item text; drop blank lines, "" and '' entries here.
    _strip_empty_refinement_entries() {
        printf '%s\n' "$1" | awk 'NF > 0 && $0 != "\"\"" && $0 != "'"'"''"'"'"'
    }
    SENDER_INCLUDES=$(_strip_empty_refinement_entries "$SENDER_INCLUDES")
    SENDER_EXCLUDES=$(_strip_empty_refinement_entries "$SENDER_EXCLUDES")
    RECIPIENT_INCLUDES=$(_strip_empty_refinement_entries "$RECIPIENT_INCLUDES")
    RECIPIENT_EXCLUDES=$(_strip_empty_refinement_entries "$RECIPIENT_EXCLUDES")
    SUBJECT_INCLUDES=$(_strip_empty_refinement_entries "$SUBJECT_INCLUDES")
    SUBJECT_EXCLUDES=$(_strip_empty_refinement_entries "$SUBJECT_EXCLUDES")
fi

# output_dir precedence (高 → 低):
#   1. $ARGUMENTS[2] (cmdline second arg) — 若已設,跳過下面的 fallback
#   2. ${CONFIG_FILE} 的 output_dir: 欄位(本 step,both zero-arg and single-arg modes)
#   3. Workspace Layout Detection(下方,v2.17.0+)
#   4. Baseline default `communication/emails`(detection 中的 Probe 3)
[ -z "$output_dir" ] && [ -n "$CFG_OUTPUT_DIR" ] && output_dir="$CFG_OUTPUT_DIR"
# last_archived feeds Step 3 search_emails 的 date_from (strict `>`)
# exclude_mailboxes feeds Step 3 mailbox-filter
```

#### Zero-arg 模式(v2.12.0+,resolves #13)

若 `$ARGUMENTS` 為空,從 `${CONFIG_FILE}` 讀取 `filters`(否則無 filter 可搜):

```bash
if [ -z "$ARGUMENTS" ]; then
    if [ ! -f "${CONFIG_FILE}" ]; then
        echo "Error: 沒有給 filter 也找不到 ${CONFIG_FILE}。" >&2
        echo "請建立 \${CONFIG_FILE} 並設定 filters,或直接傳 filter 參數。" >&2
        exit 1
    fi

    # filters → list,作 OR-search 的 filter set
    FILTERS=$(awk '/^filters:/{flag=1;next} /^[a-z_]+:/{flag=0} flag && /^  - /{sub(/^  - /,"");print}' "${CONFIG_FILE}")

    if [ -z "$FILTERS" ]; then
        echo "Error: ${CONFIG_FILE} 沒設定 filters。請補 filters 或傳命令列參數。" >&2
        exit 1
    fi
fi
```

#### 命令列覆寫(現行行為,backward compat)

若 `$ARGUMENTS` 非空,命令列參數覆寫 config:
- `filter` = 第一個 arg(視為單一 filter,即使 config 有多個 filters 仍只用此一個)
- `output_dir` = 第二個 arg(若有);**否則仍走上方 Config parsing 區段已 apply 的 `CFG_OUTPUT_DIR`**(v2.17.0+ 修掉 explicit-config-bypass-in-non-zero-arg-mode 漏洞);config 沒設則走 **Workspace Layout Detection**(v2.17.0+) / default

#### Workspace Layout Detection(v2.17.0+,#49)

當 `output_dir` 既非 `$ARGUMENTS[1]` 也非 `${CONFIG_FILE}` 的 `output_dir:` 欄位給定時,probe 工作目錄看是否符合已知的 workspace layout。**Detection 只在「沒有 explicit choice」時觸發**——如果 user 在 config 或命令列已 pin,detection 完全不跑,既有行為 100% backward compat。

**Probe 順序**(命中即停):

```bash
# Only run when output_dir is still empty after $ARGUMENTS[1] + ${CONFIG_FILE} resolution
if [ -z "$output_dir" ]; then
    # Probe 1: communications/<channel>/ pattern (v2.17.0+ canonical)
    if [ -d "communications/email" ]; then
        # Ambiguity guard: if both layouts have content, refuse to guess
        if [ -d "correspondence/emails" ] && \
           [ -n "$(find -P correspondence/emails -maxdepth 1 -name '*.md' 2>/dev/null | head -1)" ] && \
           [ -n "$(find -P communications/email  -maxdepth 1 -name '*.md' 2>/dev/null | head -1)" ]; then
            echo "❌ Ambiguous workspace layout: both 'communications/email/' and 'correspondence/emails/' have archived markdowns." >&2
            echo "   Pin 'output_dir:' in .claude/.mail/config.yaml to disambiguate." >&2
            exit 1
        fi
        output_dir="communications/email"
        echo "🔍 Detected output_dir: communications/email (from layout probe)"

    # Probe 2: correspondence/emails/ legacy pattern (pre-v2.17 user convention)
    elif [ -d "correspondence/emails" ]; then
        output_dir="correspondence/emails"
        echo "🔍 Detected output_dir: correspondence/emails (legacy layout probe)"

    # Probe 3: nothing detected — fall back to baseline default
    else
        output_dir="communication/emails"
        # No log line — silent default keeps non-detection workspace flow unchanged
    fi
fi
```

**Why probe order = `communications/email` → `correspondence/emails` → default**:

1. `communications/<channel>/` 是 forward direction(per kiki830621/chchen-lab 2026-05-08 reorg)。當 user 已建好 `communications/email/`,intent 明確。
2. `correspondence/emails/` 是 legacy convention(per 既有 `psychophysic_representations` 等 workspaces)。但這些 workspaces 通常已有 explicit `output_dir:` 在 config,此 probe 主要為「legacy workspace 沒寫 config」的少數情境兜底。
3. 都不符合則用 baseline default,既有 zero-config flow 不變。

**Ambiguity guard**:當 `communications/email/` 與 `correspondence/emails/` **同時存在且都有 `*.md`** 時,refuse 而非 silent guess。Mid-migration 的 workspace 必須 explicit pin,否則風險:detection 把新信寫到 `communications/email/` 但 dedup index 依然指 legacy 路徑,半實作狀態下的 message-id collision 不會被偵測。Empty-dir-as-marker 不算ambiguity(常見:user 才剛建好 `communications/email/`,還沒 archive 過)。

**Detection 與 explicit config 的關係**(precedence,高 → 低):

1. `$ARGUMENTS[1]`(命令列 `/archive-mail <filter> <output_dir>` 的第二個參數)
2. `${CONFIG_FILE}` 的 `output_dir:` 欄位(zero-arg 模式)
3. **Workspace Layout Detection**(本節,v2.17.0+)
4. Baseline default `communication/emails`

#### 模糊 filter

不論來源(命令列 / config),若 filter 為模糊詞 → 進 Step 1.5 disambiguation。

### Step 1.5: Confirmation — Phase 1: Disambiguation（v2.7.0+）

**Skill ref**: `confirmation-protocol`、`email-search-disambiguation`

如果 filter 是模糊詞（中文人名「陳老師」、相對時間「最近」、通用 scope「全部」），**不要直接執行 search**。先用 disambiguation:

```
「{filter}」可能對應到:
1. {email_1} ({description_1}, 推薦)
2. {email_2} ({description_2})
3. 其他

你要哪一個?
```

候選來源:
- `.claude/emails.md` 的 `participant_aliases` 欄位
- 之前歸檔的 `.threads.json` participants
- Address book / contacts MCP

**Skip Phase 1**(可直接進 Step 2):
- Filter 是明確 email 地址(含 `@`)
- Filter 是 Message-ID
- 單一 user-typed `--no-confirm` flag 或明確說「直接做」

詳見 `skills/confirmation-protocol/SKILL.md` 和 `skills/email-search-disambiguation/SKILL.md`。

### Step 1.6: 解析 namespace 路徑（v2.8.0+,學 IDD `.claude/.idd/` pattern）

統一所有 mail 工作流的 config + state 到 `.claude/.mail/`(學 idd 的 namespace 收斂):

```bash
NAMESPACE_DIR=".claude/.mail"

# Slug for output_dir (用於支援多個 archive target 並存)
SLUG=$(echo "${output_dir}" | tr '/' '-' | sed 's/^[-.]*//;s/[-.]*$//')

INDEX_DIR="${NAMESPACE_DIR}/state/archives/${SLUG}"
INDEX_FILE="${INDEX_DIR}/email_index.json"
THREADS_FILE="${INDEX_DIR}/threads.json"

# v2.16.0+ (#47): config 改 .yaml 為 first-class;.md 維持 fallback 直到 v3.0
# Auto-migrate legacy .md → .yaml 時機在下方 "Auto-migrate" 區塊處理
CONFIG_FILE="${NAMESPACE_DIR}/config.yaml"
[ ! -f "$CONFIG_FILE" ] && [ -f "${NAMESPACE_DIR}/config.md" ] && CONFIG_FILE="${NAMESPACE_DIR}/config.md"

mkdir -p "${INDEX_DIR}"
```

**Resolve dedup strategy** (v2.14.0+, issue #18):

```bash
# Default: index-based dedup (backward compat with v2.13.0 ↓)
DEDUP_STRATEGY=$(awk '/^dedup_strategy:[ \t]*/{sub(/^dedup_strategy:[ \t]*/,"");print;exit}' "${CONFIG_FILE}" 2>/dev/null)
DEDUP_STRATEGY="${DEDUP_STRATEGY:-index}"

case "$DEDUP_STRATEGY" in
    index|last_archived|both) ;;  # valid
    *)
        echo "Error: invalid dedup_strategy '${DEDUP_STRATEGY}'. Valid: index | last_archived | both" >&2
        exit 1
        ;;
esac

# If last_archived strategy: require last_archived field present
if [ "$DEDUP_STRATEGY" = "last_archived" ]; then
    LAST_ARCHIVED=$(awk '/^last_archived:[ \t]*/{sub(/^last_archived:[ \t]*/,"");print;exit}' "${CONFIG_FILE}" 2>/dev/null)
    if [ -z "$LAST_ARCHIVED" ]; then
        echo "Error: dedup_strategy=last_archived requires '${CONFIG_FILE}' to have a 'last_archived: YYYY-MM-DD' field." >&2
        echo "Either set last_archived (manually or after first archive run) or use dedup_strategy: index | both." >&2
        exit 1
    fi
fi
```

| `dedup_strategy` | Step 2 (load index) | Step 4 (dedup logic) | Step 5/6 (write index) |
|------------------|---------------------|----------------------|-----------------------|
| `index` (default) | load `email_index.json` | filter Message-ID not in index | append new Message-IDs |
| `last_archived` | skip | filter received-date `>` last_archived | skip |
| `both` | load | union: not-in-index AND date `>` last_archived | append (索引 still maintained) |

**Auto-migrate from legacy paths**(silent,只在新位置不存在時觸發):

```bash
# Legacy → new: indices
if [ ! -f "${INDEX_FILE}" ] && [ -f "${output_dir}/.email_index.json" ]; then
  mv "${output_dir}/.email_index.json" "${INDEX_FILE}"
  echo "🔄 Migrated ${output_dir}/.email_index.json → ${INDEX_FILE}"
fi
if [ ! -f "${THREADS_FILE}" ] && [ -f "${output_dir}/.threads.json" ]; then
  mv "${output_dir}/.threads.json" "${THREADS_FILE}"
  echo "🔄 Migrated ${output_dir}/.threads.json → ${THREADS_FILE}"
fi

# Legacy → new: config v2.7.0 ↓ (.claude/emails.md → namespace)
if [ ! -f "${NAMESPACE_DIR}/config.yaml" ] && [ ! -f "${NAMESPACE_DIR}/config.md" ] && [ -f ".claude/emails.md" ]; then
  mv ".claude/emails.md" "${NAMESPACE_DIR}/config.yaml"
  CONFIG_FILE="${NAMESPACE_DIR}/config.yaml"
  echo "🔄 Migrated .claude/emails.md → ${NAMESPACE_DIR}/config.yaml"
fi

# Legacy → new: config v2.15.0 ↓ (.md → .yaml, v2.16.0+ #47)
# 只 rename,不改內容(awk parser 對 YAML body 兩種格式皆 work)
if [ ! -f "${NAMESPACE_DIR}/config.yaml" ] && [ -f "${NAMESPACE_DIR}/config.md" ]; then
  mv "${NAMESPACE_DIR}/config.md" "${NAMESPACE_DIR}/config.yaml"
  CONFIG_FILE="${NAMESPACE_DIR}/config.yaml"
  echo "🔄 Migrated ${NAMESPACE_DIR}/config.md → ${NAMESPACE_DIR}/config.yaml (v2.16.0+ schema rename)"
fi
```

> **v2.16.0+ schema clarification (#47)**:config 副檔名改 `.yaml`(內容向來都是 YAML,只是 v2.15.0 ↓ 用 `.md` 副檔名造成語意 mismatch)。Auto-migrate 是 silent rename,user 不需動手。`.md` 仍 work 為 fallback,**v3.0 移除**;期間 README / CLAUDE.md schema 範例都改示範 `.yaml`。

或者用 `/archive-mail-migrate` 批次 migrate 所有舊 archive targets,詳見該 command。

### Step 2: 建立目錄和載入索引

```bash
mkdir -p "${output_dir}"   # archive markdown 目的地(不變)
```

**讀取兩個索引檔**(v2.8.0+ 從 `${INDEX_DIR}/` 讀;v2.14.0+ 條件 skip per `dedup_strategy`):

`${INDEX_FILE}` (`.claude/.mail/state/archives/${SLUG}/email_index.json`) — Message-ID 去重索引(canonical key):
- 若 `dedup_strategy=last_archived`(v2.14.0+) → **skip**, 完全不讀 index
- 若 `dedup_strategy=index`(default)或 `both` → 載入已歸檔 Message-ID;不存在則建立空索引 `{"version": "1.0", "emails": {}}`

`${THREADS_FILE}` (`.claude/.mail/state/archives/${SLUG}/threads.json`) — Thread 關係索引(append-only thread view):
- 若存在,載入既有 thread 結構
- 若不存在,建立空索引 `{"version": "1.0", "threads": {}}`
- 格式見 Step 5.7

兩個索引**獨立維護**,thread 索引純粹為了快速查詢 thread 關係,不影響單封信的儲存。若 `threads.json` 損壞,可用 `/archive-mail-rebuild-threads` 從 md frontmatter 重建。

#### Step 2.1: Sibling-archive dedup extension(v2.17.0+,#49;v2.38.0+ #285 泛化)

把「使用者已在別處歸檔過」的信件 `message_id` 併入 in-memory dedup set,**讀取 only**,涵蓋兩種來源:

1. **Symlinked siblings**(v2.17.0+,#49)— `${output_dir}` 下的 symlinked subdirectory(典型:transitioned-project pattern,例如 chchen_lab 把 `email/application/` symlink 到 `applications/completed/.../emails/`)。
2. **Distributed archives**(v2.38.0+,#285)— config `distributed_archives:` 列的分派去向目錄(**不限 symlink、不限在 `output_dir` 底下**),支援 **capture-then-distribute** 工作流:一個廣義 filter 的 capture config 把信抓進 staging,使用者再把屬於某子專案的信搬進各子專案的 archive;下次 capture 更新時,已分派信件的 `message_id` 已在 dedup set → **不重抓、不需手動 tombstone**。

兩種來源都掃 markdown 的 YAML frontmatter `message_id:`,併入同一個 `EXTENDED_DEDUP_IDS`;**從不寫入 target**。

```bash
# Only run when dedup_strategy uses index (skip if last_archived only)
if [ "$DEDUP_STRATEGY" = "index" ] || [ "$DEDUP_STRATEGY" = "both" ]; then
    # Find symlinked subdirectories in output_dir (1 level deep)
    EXTENDED_COUNT=0
    EXTENDED_SOURCES=()
    while IFS= read -r symlink_dir; do
        [ -z "$symlink_dir" ] && continue
        # Bound search depth + use -P to NOT follow symlinks recursively (we follow once into the symlinked dir, then stay)
        ENTRIES_THIS_DIR=0
        while IFS= read -r mdfile; do
            [ -z "$mdfile" ] && continue
            # Read just the YAML frontmatter (first ~30 lines is generous)
            mid=$(head -30 "$mdfile" 2>/dev/null | awk '/^message_id:[ \t]*/{sub(/^message_id:[ \t]*"?/,"");sub(/"?$/,"");print;exit}')
            if [ -n "$mid" ]; then
                # Add to in-memory dedup set (Message-ID is canonical key, same as INDEX_FILE)
                # Implementation: append to a shadow set the dedup logic in Step 4 will consult
                EXTENDED_DEDUP_IDS+=("$mid")
                ENTRIES_THIS_DIR=$((ENTRIES_THIS_DIR + 1))
            fi
        done < <(find -P "$symlink_dir/" -maxdepth 2 -name "*.md" -type f 2>/dev/null)

        if [ "$ENTRIES_THIS_DIR" -gt 0 ]; then
            EXTENDED_COUNT=$((EXTENDED_COUNT + ENTRIES_THIS_DIR))
            EXTENDED_SOURCES+=("$symlink_dir ($ENTRIES_THIS_DIR entries)")
        fi
    done < <(find -P "${output_dir}" -maxdepth 1 -type l 2>/dev/null)

    # v2.38.0+ (#285): distributed_archives — capture-then-distribute. Fold the
    # message_id frontmatter of arbitrary distribution-target dirs (from config
    # `distributed_archives:`; NOT symlinks, NOT necessarily under output_dir)
    # into the SAME EXTENDED_DEDUP_IDS set, so a capture-layer config never
    # re-pulls mail the user already distributed to a sub-project — no manual
    # tombstone needed. Read-only (find + head + awk only, never mv/rm/>).
    # A missing dir WARNS (never silent): a wrong path would silently miss dedup
    # → re-pull, the exact pain #285 fixes.
    while IFS= read -r dist_dir; do
        [ -z "$dist_dir" ] && continue
        if [ ! -d "$dist_dir" ]; then
            echo "⚠️  distributed_archives: '$dist_dir' not found — skipping (resolved relative to the workspace root; fix the path or dedup will miss and re-pull)" >&2
            continue
        fi
        ENTRIES_THIS_DIR=0
        while IFS= read -r mdfile; do
            [ -z "$mdfile" ] && continue
            mid=$(head -30 "$mdfile" 2>/dev/null | awk '/^message_id:[ \t]*/{sub(/^message_id:[ \t]*"?/,"");sub(/"?$/,"");print;exit}')
            if [ -n "$mid" ]; then
                EXTENDED_DEDUP_IDS+=("$mid")
                ENTRIES_THIS_DIR=$((ENTRIES_THIS_DIR + 1))
            fi
        done < <(find -P "$dist_dir/" -maxdepth 2 -name "*.md" -type f 2>/dev/null)
        if [ "$ENTRIES_THIS_DIR" -gt 0 ]; then
            EXTENDED_COUNT=$((EXTENDED_COUNT + ENTRIES_THIS_DIR))
            EXTENDED_SOURCES+=("$dist_dir ($ENTRIES_THIS_DIR entries, distributed)")
        fi
    done <<< "$DISTRIBUTED_ARCHIVES"

    if [ "$EXTENDED_COUNT" -gt 0 ]; then
        echo "🔗 Extended dedup with $EXTENDED_COUNT entries from sibling archives:"
        for src in "${EXTENDED_SOURCES[@]}"; do
            echo "   - $src"
        done
    fi
    # Silent when zero — typical zero-symlink workspace flow stays clean
fi
```

**Step 4 dedup logic 銜接**:`EXTENDED_DEDUP_IDS` 由 Step 4 透過 set union **併入** existing predicate(不取代 strategy-specific date filter)。完整 pseudocode 見 [Step 4 過濾新郵件](#step-4-過濾新郵件)。Composition rule 摘要:

- `dedup_strategy=index`:`known_ids = existing_index_ids ∪ extended_ids`,filter by Message-ID set membership only
- `dedup_strategy=last_archived`:本 step 2.1 完全 skip(`EXTENDED_DEDUP_IDS` 不會被 populate),Step 4 仍走 date gate
- `dedup_strategy=both`:`known_ids = existing_index_ids ∪ extended_ids` AND date > `last_archived`,**两条件 AND**(extended IDs 不打破 date filter)

**Properties / invariants**:

- **Read-only**:never `mv` / `rm` / `>` against symlink target 或 distributed archive;`find` + `head` + `awk` only。
- **Bounded**:`find -P -maxdepth 2`(dir 本身 + 一層 immediate children),對 symlink siblings 與 distributed archives 皆同,避免 deep archive 拖慢 startup。
- **`distributed_archives` missing-dir WARNS(never silent,#285)**:symlink siblings 掃不到就靜默(它們本就 opt-in symlink);但 distributed archive 是使用者手寫的 config 路徑,打錯或 dangling 會讓 dedup **silently miss → 重抓**(正是 #285 要修的痛點),所以路徑不存在必 emit `⚠️` 到 stderr,不 silent skip。路徑相對於 workspace root 解析。opt-in:config 沒設 `distributed_archives:` 時完全 no-op,行為與 v2.37.0 100% 相同(backward compatible)。
- **archive-mail v2.6+ format compatibility**:設計 target 是 archive-mail 自產的 frontmatter(`message_id: "<...>"` 雙引號格式)。Manual archive 若 frontmatter 用單引號 / 內含 inline comment / CRLF / trailing whitespace,parser 不 silent skip,而是把**malformed key**(例如 `'<abc>'` 包含單引號、含 inline comment 文字、含 `\r`)加入 in-memory dedup set;Step 4 比較 archive-mail 寫的 canonical Message-ID(`<abc>` 無外引號)時對不上,造成 **dedup miss**(historic 已 archive 的信被 re-archive)。**ENTRIES_THIS_DIR 仍會 increment**(parser 認為「成功 extract」),但 key 是 garbage,有 silent miss 風險。Future hardening(yq parser / robust awk handling 單引號 / inline comment / CRLF / trailing whitespace)deferred until N≥3 user reports of manual-archive missed dedup — see follow-up #54 / #50 for tracking。
- **Compose with `dedup_strategy`**:僅在 `index` / `both` strategy 跑;`last_archived` strategy 完全 skip(那種 strategy 的 user 顯然不依賴 Message-ID dedup)。Compose 邏輯:`EXTENDED_DEDUP_IDS` 透過 set union 併入 existing Message-ID set,不取代 strategy-specific date predicate。

**讀取附件設定**(可選):檢查 `${CONFIG_FILE}` (`.claude/.mail/config.md`) 是否有 `attachment_routing` YAML front matter 區塊。
若有，載入自訂規則（all-or-nothing 取代，不做 merge）。若無，使用以下內建預設：

```yaml
attachment_routing:
  data_extensions: [csv, tsv, sav, dta, parquet, feather, xlsx, sas7bdat]
  document_extensions: [pdf, docx, doc, txt, md, rtf, odt]
  data_keywords: [data, raw, indicators, codebook, dataset]          # 大小寫不敏感子字串匹配
  document_keywords: [Submission, Figures, Tables, Manuscript, draft, Revision, v1, v2, v3]
  data_dir: data/raw
  documents_dir: correspondence/attachments
```

**讀取搜尋擴展設定**（可選，v2.4.0+）：

```yaml
subject_keywords: [taxometric, SSQ, paper]    # subject 關鍵字搜尋（補抓 sender 漏掉的 internal threads）
participant_aliases:                           # 成員別名（用於 audit 報告顯示）
  "b08801008@ntu.edu.tw": "Pei-Chi"
  "r13227202@ntu.edu.tw": "Pei-Chi"
```

- `subject_keywords`：可選。若有，Step 3 會做第二輪 subject 搜尋。若無，只跑 sender 搜尋（向後相容）。
- `participant_aliases`：可選。目前用於 audit 報告的顯示名稱；不影響搜尋行為。

**分類優先序**（config > keyword > extension）：
1. YAML config 明確指定 → 最高
2. 檔名 keyword 子字串匹配（先比 `data_keywords`，再比 `document_keywords`）→ 中
3. 副檔名匹配（先比 `data_extensions`，再比 `document_extensions`）→ 最低
4. 全部未命中 → 保守預設：歸類為 document

### Step 3: 搜尋郵件（使用 apple-mail MCP）

使用 `mcp__plugin_che-apple-mail-mcp_mail__search_emails` 搜尋：

1. **搜尋收到的郵件**（sender 包含 filter）
2. **搜尋寄出的郵件**（scoped 到 Sent 信箱）

需要先用 `mcp__plugin_che-apple-mail-mcp_mail__list_accounts` 取得帳號列表，並對每個帳號跑 `get_special_mailboxes(account_id=...)` 解析 **Sent / Drafts / Trash 實名**（#179；不要 hardcode 英文名——本地化帳號可能叫「寄件備份」「草稿」「垃圾桶」）。實名同時供下方 (1) 的後過濾與 (2) 的 scope 使用（plugins#109 機械化）。

對每個帳號執行兩類搜尋：

**(1) 收到的郵件**（跨匣搜尋，sender 比對 filter）：
```
mcp__plugin_che-apple-mail-mcp_mail__search_emails(
  account_name: "帳號名稱",
  query: "${filter}",
  field: "sender",
  limit: 100
)
```
結果**必須**對每筆的 `mailbox` 欄位套用下方**mailbox 後過濾規則**的統一 drop-set——草稿、垃圾桶不進 corpus。

> **mailbox 後過濾比對規則（plugins#109 verify，全 Step 3 適用）**：`search_emails` 結果的 `mailbox` 是**完整解碼路徑**（Gmail 巢狀匣如 `[Gmail]/草稿`、`[Gmail]/寄件備份`），而 `get_special_mailboxes` 回的實名是**葉名**（`草稿` / `寄件備份`）——**不可用裸字串 `==` 比對**（會靜默 no-op：草稿漏進 corpus、keep-only-Sent 丟光寄出信）。`matchesSpecial(result.mailbox, 實名)` 為真 iff **完整路徑相等**，或 **`result.mailbox` 以 `/實名` 結尾（末段相等）**。末段相等**單獨用不安全**：使用者自建資料夾（如 `專案/草稿`）會與 Drafts 葉名衝突——結果集中出現同末段的非特殊匣時，改用完整路徑判別或**停下確認**，勿靜默丟棄/保留。每帳號記錄實際觀察到的 `mailbox` 值供 audit。**統一 drop-set** = Drafts ∪ Trash ∪ `exclude_mailboxes` 配置列出的匣；本規則適用 recipe (1)、3b、3c、Tier 2 的 keep-only-Sent 判定，以及 Step 8b 稽核分母（thread 完整性檢查的 total 計數同樣要對每筆 `mailbox` 套 drop-set，勿裸 `==`）。

**(2) 寄出的郵件**（scoped 搜尋，recipient 比對 filter）：
```
mcp__plugin_che-apple-mail-mcp_mail__search_emails(
  account_name: "帳號名稱",
  query: "${filter}",
  field: "recipient",
  mailbox: "<該帳號的 Sent 實名>",
  limit: 100
)
```

結果加入 corpus（與 recipe (1) 等地位，見 3d 的四組合併）。

> **Bcc 注意**：`field: "recipient"` 比對 recipients 表、不分 To/Cc/Bcc；但 **Bcc 是否被 Envelope Index 收錄無法保證**。若任務需涵蓋 Bcc-only 寄件，直接稽核 Sent 匣（unscoped + keep-only-Sent）或人工確認。

> **Tier 2 兜底（scoped 回 0 筆 → 一律執行）**：`mailbox` 參數在 SQLite 層以 percent-encoding 比對 mailbox URL，CJK / `[Gmail]` 括號路徑有編碼不匹配的已知風險。**scoped 搜尋回 0 筆就一律**退回 **unscoped** 搜尋（同上但不帶 `mailbox`）——fallback 經 Message-ID 去重、冪等，寧可多跑——再對結果 `mailbox` 欄位以上方**比對規則**判定：**只保留** Sent。Tier 2 也回 0 筆才記錄為「該帳號無寄出信」。兩層結果都以 Message-ID 去重收斂（見下方紀律 3）。

> **⚠️ account_name 陷阱（fixes #15）— 全域適用，`search_emails` 與 `get_email` 皆然**
> `list_accounts` 對 Exchange 帳號回傳的 `name` 是 `ews://AAMkA...` 形式的內部 URL；`uuid` 也不接受。後續呼叫 `get_email` / `search_emails` 時必須改用 **display name**（email 地址，例如 `user@example.com`），否則會觸發：
>
> ```
> AppleScript error (-1728): Mail got an error: Can't get account "ews://...".
> ```
>
> 若配置 `.claude/emails.md` 的 `accounts` 欄位明列 email 地址，可直接拿來用。否則需要人工比對帳號。
> **此陷阱對 Step 5 讀取郵件內文同樣適用**，不要假設搜尋階段記的 `account_name` 可以直接沿用——若那是 EWS URL，到 `get_email` 會重現 -1728。

> **⚠️ All Mail 超集陷阱（mail#261）— 寄出信判定不可用 `[Gmail]/全部郵件`**
> Gmail 的「全部郵件」是超集：**同時包含草稿**。用「全部郵件 + sender 搜尋」撈寄出信會把同一封信的**草稿版與寄出版各算一次**，甚至把未寄出的草稿當寄出信歸檔（可重現徵兆：同一 thread 出現「相同時間戳」的 `全部郵件` + `草稿` 配對——只有無配對草稿的才是真寄出）。
> **direction 亦然（mail#316）**：全部郵件是雙向超集，「信在哪個 mailbox」不可作為 `direction` 依據——寄出信照樣存在全部郵件。direction 的唯一正確依據是 sender identity（binary v2.26.0+ 的 batch 工具已 server-side per-email 判定；Step 5.1 fallback 的 client-side 規則見 frontmatter 欄位說明）。
> 紀律（機械化 recipe 見上方 (1)/(2)，plugins#109）：
> 1. **寄出信一律搜 Sent mailbox** — 由上方 recipe (2) 的 `mailbox: <Sent 實名>` scoped 呼叫落實；scoped 回 0 筆**一律**走 Tier 2 兜底（unscoped + 依 mailbox 後過濾規則 keep-only-Sent）
> 2. **落實 Drafts/Trash 排除** — 由上方 recipe (1) 的統一 drop-set 後過濾落實（比對依 mailbox 後過濾規則，勿裸 `==`）；實名一律來自 `get_special_mailboxes`，不 hardcode 英文名
> 3. 結果一律以 **Message-ID 去重**（草稿與寄出版 Message-ID 不同，但同信多匣重複會被擋）

**3b. Subject-keyword 搜尋**（v2.4.0+，若 `subject_keywords` 有設定）：

對每個 keyword，執行：
```
search_emails(account_name: "...", query: keyword, field: "subject", limit: 100)
```

結果同樣套上方 **mailbox 後過濾規則**的統一 drop-set（subject 搜尋跨匣，草稿同樣會混進來，plugins#109）。

將過濾後的結果加入 corpus。

**3c. Thread-subject 擴展**（v2.4.0+，自動）：

對步驟 3 / 3b 找到的每封信：
1. 提取 bare subject（去掉 `Re:` / `Fwd:` / `FW:` / `转发:` / `轉寄:` / `回覆:` / `回复:` 前綴，**不分大小寫**，用正則 `(?i)^(Re|Fwd|FW|转发|轉寄|回覆|回复):\s*`——對齊 batch 工具與 frontmatter thread_key 的 superset，plugins#107 Fix 3）
2. 用 bare subject 搜尋：`search_emails(query: bare_subject, field: "subject", limit: 100)`
3. 對結果套用上方 **mailbox 後過濾規則**的統一 drop-set（thread 擴展跨匣，是草稿重新混入的第二條路徑，plugins#109 verify），再加入 corpus

**3d. 合併去重**：

**四組結果**（sender + **recipient/sent** + subject_keywords + thread-subject）用 Message-ID 去重。最終 corpus 進入 Step 4。

在 Step 7 報告中加上：`搜尋結果: {sender_count} by sender + {sent_count} by recipient/sent + {keyword_count} by subject + {thread_count} by thread expansion = {total_unique} unique`

### Step 4: 過濾新郵件

Step 4 分兩個 sub-step:**先 Layer 2 pre-dedup refinement**(v2.20.0+,新,#76 + #84),**再 dedup**(原行為)。

#### Step 4.0: Pre-dedup refinement (Layer 2, v2.20.0+, #76 + #84)

Refinement executes after fetch and before dedup,對應 spec `openspec/specs/archive-mail-corpus-refinement/spec.md`。6 個 opt-in config 欄位(`sender_includes` / `sender_excludes` / `recipient_includes` / `recipient_excludes` / `subject_includes` / `subject_excludes`)在 thread 層級過濾 fetched corpus:case-insensitive substring matching with bare-value normalization、per-axis includes whitelist and excludes blacklist with excludes-precedence、per-thread coherence(任一 message 命中 → 整 thread keep/drop)。

實作 sketch:

```python
import re

_RE_FWD_PREFIX = re.compile(r'^(Re|Fwd|FW|转发|轉寄|回覆|回复):\s*', re.IGNORECASE)  # superset, plugins#107 Fix 3

def _bare_email(addr_field):
    """Strip display name. '"Name" <foo@bar>' → 'foo@bar'; lowercase."""
    m = re.search(r'<([^>]+)>', addr_field or "")
    raw = m.group(1) if m else (addr_field or "")
    return raw.strip().strip('"').lower()

def _bare_subject(subject):
    """Strip leading Re:/Fwd:/FW:/转发:/轉寄:/回覆:/回复: prefixes (case-insensitive); lowercase."""
    s = subject or ""
    while True:
        m = _RE_FWD_PREFIX.match(s)
        if not m: break
        s = s[m.end():]
    return s.strip().lower()

def _matches_any_substring(target_lower, substrs):
    """Case-insensitive substring matching with bare-value normalization (target already lowered)."""
    return any(s.strip().lower() in target_lower for s in substrs if s.strip())

def _thread_passes_refinement(thread_messages, config):
    """Per-axis includes whitelist + excludes blacklist with excludes-precedence.
    Per-thread coherence: any message matches includes → keep thread; any matches excludes → drop thread."""
    senders    = [_bare_email(m['sender']) for m in thread_messages]
    recipients = [_bare_email(r) for m in thread_messages for r in (m.get('to', []) + m.get('cc', []))]
    subjects   = [_bare_subject(m['subject']) for m in thread_messages]

    # Includes whitelist (skip axis if list empty per spec empty-list-as-unset)
    for axis_values, includes in [
        (senders,    config.get('sender_includes',    [])),
        (recipients, config.get('recipient_includes', [])),
        (subjects,   config.get('subject_includes',   [])),
    ]:
        if includes and not any(_matches_any_substring(v, includes) for v in axis_values):
            return False, 'includes_filter'  # whitelist active and no message matches → drop

    # Excludes blacklist (excludes win when both set on same axis per spec ADDED Requirement)
    for axis_values, excludes, reason in [
        (senders,    config.get('sender_excludes',    []), 'sender_excludes'),
        (recipients, config.get('recipient_excludes', []), 'recipient_excludes'),
        (subjects,   config.get('subject_excludes',   []), 'subject_excludes'),
    ]:
        if excludes and any(_matches_any_substring(v, excludes) for v in axis_values):
            return False, reason

    return True, None

def apply_refinement(fetched, config):
    """Group fetched by thread key (bare subject); drop threads per per-thread coherence rule."""
    threads = {}
    for email in fetched:
        threads.setdefault(_bare_subject(email['subject']), []).append(email)

    stats = {'kept': 0, 'dropped_sender_excludes': 0, 'dropped_recipient_excludes': 0,
             'dropped_subject_excludes': 0, 'dropped_includes_filter': 0}
    refined = []
    for thread in threads.values():
        passed, reason = _thread_passes_refinement(thread, config)
        if passed:
            refined.extend(thread)
            stats['kept'] += 1
        else:
            stats[f'dropped_{reason}'] += 1
    return refined, stats

# Pre-dedup refinement runs HERE, before the dedup pseudocode below.
refined, refinement_stats = apply_refinement(fetched, config)
```

Refinement runs **before** dedup,所以被排除的 thread Message-ID **不會**進 `email_index.json` 或 `threads.json`。同一個 refinement config 在後續 run 仍會 drop 同一批 thread,不會 re-surface 為 new。下面的 dedup pseudocode 中的 `fetched` 應視為 refinement 之後的 `refined` corpus。

#### Step 4.1: Dedup (既有行為,v2.17.0+ #49)

對每封 refined 後的郵件,依當前 `dedup_strategy` 套用 dedup logic。**v2.17.0+ #49**:除了既有 `INDEX_FILE` 來源的 Message-ID set,**也必須消費 Step 2.1 累積的 `EXTENDED_DEDUP_IDS`**(從 sibling-archive symlink 抽出的 historical Message-ID)。

```python
# Build the canonical "known" Message-ID set per dedup_strategy
existing_ids = set(load_json(INDEX_FILE)["emails"].keys()) if DEDUP_STRATEGY in ("index", "both") else set()
extended_ids = set(EXTENDED_DEDUP_IDS)  # v2.17.0+ — populated by Step 2.1 if symlinked siblings exist
known_ids = existing_ids | extended_ids

# Apply strategy-specific predicate (note: extended_ids compose IN to existing predicate, not replace it)
def is_new(email):
    # Always: not in known Message-ID set
    if email["message_id"] in known_ids:
        return False
    # Extra gate for last_archived / both: also require date > last_archived
    if DEDUP_STRATEGY in ("last_archived", "both") and LAST_ARCHIVED:
        if email["date"] <= LAST_ARCHIVED:
            return False
    return True

new_emails = [e for e in fetched if is_new(e)]
```

對每封新郵件:
1. 檢查其 Message-ID 是否已在 `known_ids`(`INDEX_FILE` ∪ `EXTENDED_DEDUP_IDS`)中
2. 若已存在 → 跳過
3. 若不存在(且通過 strategy-specific date gate)→ 加入待歸檔清單

> **Why `known_ids` 而非單純 `existing_ids`?** 對 transitioned-project workspace(see Step 2.1),`EXTENDED_DEDUP_IDS` 來自 read-only sibling archive(symlink target),這些 historical Message-ID 不在 `INDEX_FILE` 但代表「使用者已 archive 過的信」。若不消費 extended set,sibling archive 裡的舊信被 forward 回來會 silent re-archive。
>
> **`dedup_strategy=both` composition 細節**:extended IDs 透過 set union **加入** known set,而非取代。`both` strategy 的 date filter 仍照常 apply(對所有 emails,不論其 Message-ID 來源)。

### Step 4.5: Confirmation — Phase 2 + 3: Search Preview + Operation Confirmation（v2.7.0+）

**Skill ref**: `bulk-operation-preview`、`confirmation-protocol`

如果 Step 4 過濾後的待歸檔清單 **≥ 5 封**(或 ≥ 1 封 destructive op),**不要直接進 Step 5 fetch + write**。先 preview:

#### Phase 2: Search Preview

按 thread 分組,跑 false-positive detection,展示給 user:

```
搜尋結果:{N} 封 emails (filter: {filter}, output: {output_dir})

Filter:
  Mail
    -> filter(sender = '...' OR recipient = '...' OR subject contains '...')
    -> sort(date desc)

Threads 分布:
  ✓ [{date}] {thread_key} ({M} msgs)
       Participants: {p1, p2, p3}
  ⚠ [{date}] {thread_key} ({M} msgs)  ← potential false positive
       Reason: sender 不在 filter, 僅 subject 含關鍵字

Corpus refinement (includes/excludes) — v2.20.0+, only shown when ≥1 refinement field non-empty:
  Phase 2 preview surfaces refinement statistics: kept {kept} / dropped {dropped} threads.
  Dropped by sender_excludes:    {N} threads     # category omitted if N=0
  Dropped by recipient_excludes: {N} threads     # category omitted if N=0
  Dropped by subject_excludes:   {N} threads     # category omitted if N=0
  Filtered out by includes:      {N} threads     # category omitted if N=0
  (When all six refinement fields are unset or empty, the entire refinement block is omitted from preview.)

附件預估:{K} 個 ({total_size})
```

False-positive flagging 規則見 `rules/false-positive-detection.md`:
- ✓ sender/recipient 直接匹配 filter
- ⚠ email 在 thread 但不是 principal
- ⚠⚠ 只 subject keyword match,sender 不符
- ❓ metadata 不足以判斷

#### Phase 3: Operation Confirmation

```
我將執行:
  - 寫 {N} 個 markdown 檔到 {output_dir}/
  - 下載 {K} 個 attachments ({total_size}),分流到 {data_dir}/ 和 {documents_dir}/
  - 建立/更新 .email_index.json 和 .threads.json
  - 不修改 Mail.app 內容(read-only operation)

⚠ 此操作會建立約 {N+K+2} 個檔案
確認執行嗎?

選項:
  (a) 確認,全部歸檔
  (b) 排除 false positive,歸檔 {N - flagged} 封
  (c) 修改 filter 重 search
  (d) 取消
```

#### Phase 4: User response handling

- 「對」/「a」/「OK」 → 進 Step 5 執行
- 「b」/「排除 ⚠」 → 從待歸檔清單移除 flagged threads,重 confirm
- 「c」/「修改 filter」 → 回 Step 1 重新 parse
- 「d」/「取消」 → abort,不 write 任何檔案

**Skip Phase 2+3**(可直接進 Step 5):
- 待歸檔清單 < 5 封 且 沒有 false-positive flag
- User 在 Phase 1 已說「直接做」
- 配置 `.claude/emails.md` 含 `confirmation: skip`

詳見 `skills/bulk-operation-preview/SKILL.md` 和 `rules/confirmation-triggers.md`。

### Step 5: 生成 Markdown

對每封新郵件，建立 Markdown 檔案。**主路徑走 server-side 批次匯出（Step 5.0）；per-email `get_email` 迴圈（Step 5.1）為 fallback。**

#### Step 5.0: 批次匯出主路徑（plugins#107，che-apple-mail-mcp#232 SOP 側落地）

**觸發條件（全部成立才走批次）**：
- 待歸檔（Step 4 過濾後）**≥ 5 封**（對齊 Step 4.5 confirmation gate 門檻）
- **未**設 `enrichment: summary+todos`（enriched template 的 AI 摘要/待辦無法伺服器端產 → 走 Step 5.1 fallback）

否則走 Step 5.1 per-email fallback（< 5 封延遲可接受；enriched 需 client-side AI）。

**為什麼**：`batch_export_emails_markdown`（binary v2.18.0+ canonical 名，舊名 `export_emails_markdown` 為 deprecated alias）一次呼叫在**伺服器端**匯出整批，取代「per-email `get_email(format='text')` + client-side 逐封轉錄」——大批量（實測 63 封）從數十次 IPC + 轉錄降為兩次呼叫。

工具寫出的 frozen frontmatter **6 個核心欄位的名稱與順序** 與本 SOP simple template 相同（`message_id`/`thread_key`/`in_reply_to`/`date`/`sender`/`direction`），body header 為 `Subject/From/To/Cc(有才印)/Date`（simple template 的 superset）。但**不是逐位元相同**，有三處工具側的 superset 行為，Step 5.1 fallback 已依 Fix 3 對齊（見下方 frontmatter 欄位說明），避免同一 thread 因寫入路徑不同而 frontmatter 漂移：
- `thread_key`：工具的 `stripReplyPrefixes` 去除**超集**前綴（多 `回覆:`/`回复:`，且**全 case-insensitive**），比 SOP 舊 thread_key 規則廣。
- `sender`：工具剝 display name **並轉小寫**（`bareEmail().lowercased()`）。
- 工具在 6 核心欄位後**多附一個 `body_type: text|html` 第 7 欄位**（keyed consumer 無害，但非「無縫隙」）。

**direction 由伺服器 per-email 判定（binary v2.26.0+，mail#316）——整個 corpus 一批送，不再拆批**：工具對每封信以 sender identity 判定 direction（bare sender、case-insensitive ∈ 使用者全帳號 own-addresses 聯集 → `sent`，否則 `received`；own addresses 來自本機 account mapping，無 AppleScript）。`mailbox` 參數對 direction 只剩 fail-open fallback 角色（見下），**不帶即可**。

```
# 整個 corpus 一批（Step 4 去重後全部 ids）——direction 由工具逐信判定
batch_export_emails_markdown(
  ids: [<corpus 全部 ids>],
  output_dir: "${output_dir}",
  opts: { filenames: <見下 filename map> }
)
```

> **為什麼不能由 mailbox 推導（歷史教訓，mail#316）**：Gmail 寄出信存於 `[Gmail]/全部郵件`——All Mail 是**雙向超集**，mailbox 名稱結構上不攜帶 direction 資訊。舊版 SOP 的「依 mailbox 拆兩批」在 All-Mail 來源的 corpus 上把自寄信全標 `received`（實測 5 封 thread 3 封誤標、且為 frozen frontmatter 持久化）。**任何**「從信所在 mailbox 導 direction」的做法（含 per-email fallback）都同樣錯——正確依據只有 sender identity。

> **`direction_inferred: true` 消費規則（fail-open 揭露）**：own-addresses 聯集為空（如全 EWS 帳號——地址不在本機 mapping）時，工具整批回退到舊 mailbox-label 行為，並在**每個** written manifest item 標 `direction_inferred: true`（negative-only：identity 判定成功的 item **無**此欄位）。SOP 消費：偵測到任一 item 帶此欄位 → 在 **Step 7 報告揭露**「該批 direction 為 mailbox-label 推測、非 sender-identity 判定」；混合向 corpus 且出現此欄位時，direction 不可信，逐封改走 Step 5.1（以下方 sender-identity 規則 client-side 判定）。

> **版本邊界**：binary **< v2.26.0** 無 per-email 判定（`mailbox` 參數 substring 標整批、manifest 無 `direction_inferred` 鍵）→ 必須沿用舊「依 direction 拆兩批」紀律（見本檔 git history 的舊版 Step 5.0），或先升級 binary。偵測法：manifest item 全無 `direction_inferred` 且 binary 版本 < 2.26.0。

**`opts.filenames`（保留歷史命名慣例，必傳——但只是「請求」名，不是最終權威）**：工具**預設** filename 吃已 `stripReplyPrefixes` 的 threadKey **且合併連續 dash**（`Re: x` → `x`），會偏離本 SOP 的 50 檔命名慣例（保留 `Re--`、不合併）。故對每個 id 用 **Step 5.1 的 filename 規則**（見下方「檔名格式」——從 raw subject 算，保留 `Re:`→`Re--`、不合併連續 `-`、截 50 graphemes、`-N` 碰撞後綴）算出檔名，組成 `{ id: "YYYY-MM-DD_{subject}.md", … }` 傳入。所需 (id, date, subject) 在 Step 4.5 preview 已有，**不需 body fetch**。

> **最終檔名以 manifest `written_path` 為準（關鍵）**：工具對**每個** filename branch（含 `opts.filenames` override）都會 seed 自 output_dir 既存 `.md`（不分大小寫）再套 `uniquify()`，故傳入的名字若與**磁碟既存**或**跨兩批（批 A 先寫、批 B 後寫）**撞名，工具會自行加 `-N` 後綴寫成另一個檔。因此 `opts.filenames[id]` 只是**請求**名——client 端算的 `-N`（下方 Glob）是 best-effort，工具的 cross-call、case-insensitive `uniquify` **贏**。**任何 downstream 用途（Step 5.5 的 stem、Step 6 index 的 `file`）一律讀回 manifest item 的 `written_path`（basename），絕不用 `opts.filenames` map**。client 端仍算 `-N`（同一 (date,subject) 先 Glob 磁碟現有最大 `-N`、本批內多封依序遞增）只是為了讓請求名盡量命中、減少工具再改名，非最終權威。

**不帶 `opts.include_attachments`**：工具的附件分流只按副檔名（data ext → `output_dir/data/`、其餘 → `output_dir/attachments/<stem>/`），**缺** SOP Step 5.5 的 keyword classify、inline `cid:` 圖片、cross-reference。附件仍走 client-side **Step 5.5**（對 batch 已寫出的每封 md 照跑）。

**dedup**：Step 4 已對 `${INDEX_FILE}` 做 Message-ID dedup，傳入的 ids 已是新信。可選傳 `skip_message_ids_path`（指向一份 INDEX_FILE Message-ID 清單，一行一個）作為 belt-and-suspenders 防 index/corpus drift；工具會把命中者標 `status: "skipped"` 不重寫。

**保留 manifest（供 Step 8.5 Phase 0 消費，plugins#110）**：批次呼叫回傳的 manifest（單一主呼叫；含 skip_partial re-export 補呼叫時一併保留） **必須留存到記憶體**（或 run-scoped 暫存）供 Step 8.5 的 manifest-driven Phase 0 使用。結構：頂層 `{output_dir, written, errors, skipped, items:[…]}`（頂層 5 鍵恆在，count 為衍生）。每個 item **恆有** `{id, status ("written"|"error"|"skipped"), attachments}`；**條件性**（可能缺）`message_id`、`written_path`、`attachment_errors`、`error`（惟 `status:"written"` item **必帶** `message_id` + `written_path`——見下方誠實邊界）。

⚠️ **manifest 欄位的誠實邊界**（downstream 必守）：
- `status: "error"` item **恆無** `written_path`；`message_id` **視錯誤階段而定**（write-error / filename-escape-error 兩 branch 仍帶 `message_id`，fetch-error 則無）→ 該 id 一律 (a) 在 Step 7 報告揭露、(b) 走 **Step 5.1 fallback** 補抓（refetch 會自 live email 重取 message_id）；不得當成已寫。
- `status: "skipped"`（dedup 命中）item 通常**無新** `written_path`。
- `direction_inferred: true`（binary v2.26.0+，mail#316）為**條件性**欄位：只在 fail-open 回退時出現於 written item（見上方消費規則）；缺席 = sender-identity 判定成功（或 binary 過舊，鍵不存在——以版本邊界區分）。
- manifest **不帶** `date`／`subject`／`thread_key`。故 Step 6 index / Step 8.5 Phase 0 若要這些欄位：`date`／`thread_key` 取自**寫出的 md frontmatter**（工具已寫入這兩個 frozen 欄位）；`subject` **不在** frontmatter（只在 body `Subject:` 行）→ 取自 **Step 4.5 preview** 的 `id→subject`（乾淨，非 body-line heuristic）。manifest 只提供「哪個 id → 哪個 message_id → 哪個 written_path」的骨架。
  > **`id→subject` preview slice 必須保留到 Step 8.5 Phase 0**：此為 Step 5.0 已依賴的同一份記憶體狀態（`opts.filenames` 也用它，見上方），Phase 0 只是延長其存活期（4.5→8.5）。若 agent 未保留、Phase 0 取不到某 id 的乾淨 subject → **fallback 讀該 md 的 body `Subject:` 行**（即 Phase 1 的 heuristic），而非寫空 subject。
- **Step 8.5 本次由 plugins#110 改為兩 phase**：Phase 0 消費本 run manifest 做機械化 reconciliation（乾淨、零 body-heuristic），Phase 1 仍全量重掃 `${output_dir}` frontmatter 收斂歷史孤兒——manifest 消費是**本次已落地**的能力。

- **partial-`.emlx` 訊號（binary v2.23.0+，mail#283 — mail#274 的 bulk 路徑閉環）**：body 尚未從伺服器下載的信（Mail 存成 `<rowid>.partial.emlx`）過去會被**靜默寫成 header-only md**。v2.23.0+ 的 manifest 帶負向訊號：item `body_downloaded: false`（僅 false 或缺席，絕不 true）+ 頂層 `body_not_downloaded` 計數（O(1) 檢查）。**SOP 消費規則**：
  1. Step 5.0 批次呼叫**一律帶 `opts.skip_partial: true`** —— header-only 信不落盤（status `"header_only"`，不佔 corpus、不產生 `-N` 疊檔），檔名 slot 仍保留（re-export 落回原名）。
  2. export 後檢查 `body_not_downloaded > 0` → 對每個 `status:"header_only"` item 的 id 跑單封 `get_email`（其 mail#274 fallback 兼作下載促發），然後**只對這些 id 重跑一次 `batch_export_emails_markdown`**（仍帶 `skip_partial:true`；再被 skip = body 仍未下載，Step 7 報告揭露、不重試迴圈）。
  3. `"header_only"` 與 dedup 的 `"skipped"` 是**不同 status**，Step 8.5 Phase 0 對兩者都不計為 written。
  4. **版本邊界**：binary < v2.23.0 無此訊號（manifest 缺 `body_not_downloaded` 鍵）→ 行為同舊（可能靜默 header-only），SOP 偵測到鍵缺席時在 Step 7 報告標註「partial 偵測不可用（binary 過舊）」。
  > ⚠️ 預設模式（不帶 `skip_partial`）的 re-fetch 迴圈**不安全**：header-only md 已實際落盤，re-export 會撞 collision guard 產生 stale + `-N` 重複檔——必須先刪 flagged item 的 `written_path` 才能重匯。帶 `skip_partial:true` 從源頭避開此 trap（工具 schema 描述同此警告）。

**批次失敗處理**：整批呼叫失敗（如 lock busy #236、FDA 不可用）→ log 後 **fallback 到 Step 5.1** per-email；部分 item `status:"error"` → 該 id 走 Step 5.1 補抓，其餘接受 batch 結果。

#### Step 5.1: Per-email fallback（原 Step 5 邏輯）

以下為 fallback 路徑（< 5 封 / enriched template / batch 失敗）。對每封新郵件，建立 Markdown 檔案。

> **⚠️ 再次提醒（來自 Step 3）**：在 Step 5 呼叫 `mcp__plugin_che-apple-mail-mcp_mail__get_email` 讀取內文時，同樣要用 **display name（email 地址）**作為 `account_name`，不可用 `list_accounts` 回的 `ews://` URL 或 UUID——否則 AppleScript error -1728。

`search_emails` 回傳**不含**完整內容（僅 subject / sender / date / mailbox / account），因此對每封新郵件先呼叫：

```
mcp__plugin_che-apple-mail-mcp_mail__get_email(
  id: "<id from search>",
  mailbox: "<mailbox from search>",
  account_name: "<display name / email 地址>",
  format: "text"
)
```


**檔名格式**（fixes #16）：`YYYY-MM-DD_{subject-hyphenated}.md`

Subject → filename 轉換規則（依此順序執行）：
1. **標點轉 `-`**：空白、冒號、斜線、反斜線、引號、問號、驚嘆號、中英標點（`,`、`。`、`、`、`:`、`；`、`(`、`)`、`[`、`]`、`?`、`!`）→ `-`
2. **路徑字元移除**：`.` 開頭的檔名加底線前綴 `_`；`..` 保留為字面（標點轉換已把 `/` 變 `-`，不會路徑越界）
3. **連續 dash 保留**：**不**合併連續 `-`（實務上 `Re:` + 空白 = `Re--`，符合 50 個歷史歸檔慣例）
4. **截斷至 50 個字元**（extended grapheme clusters，即 Swift `String.count` 的語意；非 Unicode code points、非 UTF-8 byte。`é` / `🇹🇼` / 中日韓字各算 1）
5. **首尾 `-` 去除**（截斷後若尾部是 `-`，再次去除；最終檔名不應以 `-` 結尾）
6. **空字串 fallback**：若步驟 1–5 後為空（空白 subject 或全標點 subject），使用 `no-subject`
7. **保留 Unicode**（中文、日文、韓文、emoji 維持原樣）

同日同主旨多封郵件：
- 第 1 封：**無後綴** → `2026-04-08_Re--Some-topic.md`
- 第 2 封：`-1` → `2026-04-08_Re--Some-topic-1.md`
- 第 3 封：`-2` → `2026-04-08_Re--Some-topic-2.md`
- 第 N 封（N ≥ 2）：`-{N-1}`

偵測後綴編號：用 `Glob` 列出 `YYYY-MM-DD_{subject}*.md`，取現有最大 `-N` +1（若無匹配則第 1 封無後綴；有 1 個匹配則 `-1`）。

範例（來自 `tatsuma/communications/`）：

| Subject | 順序 | 檔名 |
|---------|------|------|
| `Re: sabbatical year` | 第 1 封 | `2023-08-28_Re--sabbatical-year.md` |
| `翻訳のお願い` | 第 1 封 | `2024-03-26_翻訳のお願い.md` |
| `NTU PSY seminar 2024 final PPT` | 第 1 封 | `2024-04-04_NTU-PSY-seminar-2024-final-PPT.md` |
| `Re: Poster at 九州心理学会` | 第 4 封 | `2024-11-20_Re--Poster-at-九州心理学会-3.md` |
| `(空白 subject)` | 第 1 封 | `2026-04-08_no-subject.md` |

> **歷史相容 note**：`communications/` 有少量 `-a` / `-b` 字母後綴（如 `2024-07-14_...-a.md`）。新規不遷移舊檔，但新檔**一律用 `-1` `-2` `-3` 數字後綴**。若混用造成困擾，另開 follow-up issue。

**內容格式**(v2.13.0+ 預設簡化,issue #17;v2.6.0+ 加入 YAML frontmatter):

預設使用 **simple template**(對應 tatsuma 50 個既有檔案格式)。若 `${CONFIG_FILE}` 設 `enrichment: summary+todos`,改用下方 **enriched template** 加上 AI 摘要 + 待辦兩段。

```bash
# Step 1.6 階段已 parse;此處使用
ENRICHMENT=$(awk '/^enrichment:[ \t]*/{sub(/^enrichment:[ \t]*/,"");print;exit}' "${CONFIG_FILE}" 2>/dev/null)
ENRICHMENT="${ENRICHMENT:-none}"  # default: simple template (v2.13.0+)
```

#### Simple template (default, v2.13.0+):

```markdown
---
message_id: "<9c7a43db76e94a64a51f85d04c3bf01b@ntu.edu.tw>"
thread_key: "SE manuscript 10xx-2025"
in_reply_to: "<eddba65d53754587aeee5d86ff631d2c@ntu.edu.tw>"
date: 2026-01-28T08:35:34Z
sender: yfhsu@ntu.edu.tw
direction: received
---

Subject: <subject>
From: <sender display name OR email>
To: <recipient(s)>
Date: YYYY-MM-DD HH:MM

[完整 body]
```

Frontmatter 保留全部 6 欄位(thread index 重建仍依賴);header 改為 4 行純文字 `Subject/From/To/Date`,直接接 body,不再有元數據表 / 重點摘要 / 待辦事項三段。

#### Enriched template (opt-in via `enrichment: summary+todos`):

僅在 `${CONFIG_FILE}` 設定後觸發。Schema:

```markdown
---
message_id: "<9c7a43db76e94a64a51f85d04c3bf01b@ntu.edu.tw>"
thread_key: "SE manuscript 10xx-2025"
in_reply_to: "<eddba65d53754587aeee5d86ff631d2c@ntu.edu.tw>"
date: 2026-01-28T08:35:34Z
sender: yfhsu@ntu.edu.tw
direction: received
---

# [主題] - YYYY-MM-DD HH:MM

## 元數據

| 項目 | 內容 |
|------|------|
| **日期** | YYYY-MM-DD HH:MM |
| **類型** | 收到 / 寄出 |
| **寄件人** | xxx |
| **收件人** | xxx |

---

## 信件內容

[完整郵件內容]

---

## 重點摘要

- [AI 提取的重點]

## 待辦事項

- [ ] [AI 提取的待辦]

---

*歸檔日期：YYYY-MM-DD*
```

**Frontmatter 欄位說明**：
- `message_id`: 該封信的 RFC 5322 Message-ID（用引號包住，避免 YAML 解析角括號）。**缺值規則（mail#319，與 `in_reply_to` 同級的明文 fallback）**：工具回傳空 message_id 時，**先**用 `get_email_headers` 對同一 id 重取一次（headers 路徑與 body 路徑不同 code path，常能拿到值）；仍空 → frontmatter 寫 `message_id: ""` 並加一行 `message_id_missing: true`，讓 Step 8.5 走 `unparseable` 分支自然浮現。**明文禁止發明任何佔位符**（`synthetic:<timestamp>` 或其他）——synthetic key 的 timestamp 是執行當下時間，同一封信每次重跑產生**不同** key，對 dedup 永遠是「新信」→ 每輪重複寫入且所有 gate 全綠（mail#319 實測 84 檔 synthetic、單輪 12 封靜默重複）。既有 synthetic 檔的一次性修復見 `/archive-mail-repair-synthetic-ids`
- `thread_key`: 依下列規則計算的 bare subject（**對齊 batch 工具的 `stripReplyPrefixes`——plugins#107 Fix 3**，兩路徑同規則才不會讓同一 thread 因寫入路徑不同而 frontmatter 漂移、碎裂 threads.json）：
  1. 去掉前綴 `Re:` / `Fwd:` / `FW:` / `转发:` / `轉寄:` / `回覆:` / `回复:`——**全部不分大小寫**（`re:` / `fw:` / `fwd:` 同樣去除），重複出現多次也全部去除
  2. 去除首尾空白
  3. 保留原始（去前綴後的）大小寫和標點
  4. 若結果為空，用 `no-subject`
  > **歷史檔 caveat**：本規則之前的舊版不去 `回覆:`/`回复:` 且區分大小寫；在此之前歸檔的 md 其 thread_key 可能仍帶 `回覆:` 前綴，與新檔的 thread_key 分屬兩 thread。若某中文回覆 thread 出現此分裂，跑 `/archive-mail-rebuild-threads` 以新規則全量重算即可收斂。
- `in_reply_to`: 若有，來自郵件的 `In-Reply-To` header；若 MCP 未暴露，從 body 的 quote intro 嘗試提取第一個 Message-ID，否則留空
- `date`: ISO 8601，**保留原始 Date-header 的時區 offset**（如 `…+08:00`；對齊 batch 工具 #244，兩路徑同表示法——若舊版寫 UTC `Z` 而 batch 寫 offset，跨午夜信的檔名日期前綴會差 ±1 天）。**enforcement（mail#275）**：Date header 為 **RFC822 原樣**（`Thu, 25 Jun 2026 09:30:45 +0800 (CST)`，常見於 webmail 系統寄件）時**必須先轉 ISO 再寫入** frontmatter——`email.utils.parsedate_to_datetime(raw).isoformat()`——直接抄原樣會經 Step 6/8.5 流入 index，汙染 max(date) 計算（mail#275 實證案例即此路徑）。**offset 缺失即錯誤（mail#319）**：任何寫入的 `date` 一律**必須帶時區 offset**（`+08:00` / `Z`）——來源給 naive local time 時不得當 UTC 寫入（mail#319 同批 synthetic 檔實測 +08:00 被當 UTC，差 8 小時，汙染 `last_updated = max(date)` 且跨午夜檔名日期差一天）；無法確定 offset 時比照 unparseable 揭露，不靜默猜
- `sender`: 寄件人 email 地址（display name 剝除，**並轉小寫**——對齊 batch 工具的 `bareEmail().lowercased()`，否則 threads.json 的 participant 去重會把 `A@x` 與 `a@x` 當兩人）
- `direction`: `received` 或 `sent`。**判定規則（mail#316）**：以 sender identity 判定——bare sender（lowercase）∈ 使用者**全帳號** own addresses 聯集（`list_accounts` 各帳號 `email_addresses` 聯集）→ `sent`，否則 `received`。**絕不可由信所在 mailbox 推導**——Gmail All Mail 是雙向超集，mailbox 不攜帶 direction 資訊（mail#316 實測誤標）。此規則與 batch 工具（binary v2.26.0+）的 server-side 判定同義，兩路徑不漂移

這些 frontmatter 欄位是 **canonical truth**——`.threads.json` 僅為衍生索引。

### Step 5.5: 下載並分流附件

對每封已歸檔的新郵件,**處理兩類**:explicit MIME attachments(由 `list_attachments` 回傳)+ inline `cid:` 圖片(由 HTML body 解析,v2.15.0+ 加,issue #45)。

> **批次路徑（Step 5.0）的 stem 來源**：走 batch 匯出時，每封信的 `email_md_stem` **一律取自 manifest item 的 `written_path`（basename 去 `.md`）**，**不可**用 Step 5.0 傳入的 `opts.filenames` map——工具可能因撞名而把請求名加 `-N`（見 Step 5.0），只有 `written_path` 是實際寫出的檔名。`status:"error"` 的 item 無 `written_path`（該 id 已轉 Step 5.1 補抓），不在此處理。附件分流邏輯不變（batch 不帶 `include_attachments`，附件一律由本 step 對 batch 已寫出的每封 md 照跑）。

#### Step 5.5.0: Inline `cid:` images(v2.15.0+,resolves #45)

`list_attachments` **不**回傳 inline `cid:` 圖片(`Content-Disposition: inline`)。先從 HTML body 抽出再 download:

```bash
# Parse HTML body for inline cid references + alt-attribute filenames
# Pattern 1: <img src="cid:XXX" ... alt="filename.png">
# Pattern 2: <span id="cid:XXX">&lt;filename.tex&gt;</span>  (Mail.app quote-time marker — 已由 Step 5.5 #6 cross-reference 處理,本 step 只處理 Pattern 1)

INLINE_LIST=$(echo "$HTML_BODY" | python3 -c "
import re, sys, html
body = sys.stdin.read()
# 抓 <img ... cid:XXX ... alt='...'>;tolerant 大小寫 + 屬性順序
pattern = re.compile(
    r'<img\b[^>]*?src=[\"\\']cid:([^\"\\']+)[\"\\'][^>]*?alt=[\"\\']([^\"\\']+)[\"\\']',
    re.IGNORECASE | re.DOTALL
)
seen = set()
for m in pattern.finditer(body):
    cid, alt = m.group(1), html.unescape(m.group(2))
    if cid not in seen:
        seen.add(cid)
        print(f'{cid}\t{alt}')
")
```

對每個 `(cid, alt_filename)` pair:

1. **目標路徑**:`{documents_dir}/{email_md_stem}/inline/{alt_filename}`
   - 與 explicit attachments 同 stem 資料夾,但放 `inline/` 子目錄
   - filename 保留原始 alt(空白 / emoji / 中日文都不改)
   - 若 `documents_dir/{email_md_stem}/inline/` 不存在,先 `mkdir -p`

2. **下載**:呼叫 `save_attachment(attachment_name=alt_filename, save_path=...)`
   - **預期假設**:Apple Mail binary 接受 inline filename(尚未驗證,需要實測)
   - 若 `save_attachment` 失敗 → log warning + 改用 cross-reference 註記(見 Step 5.5.5),不中斷歸檔
   - 若 alt 屬性失敗解析(例如 charset 異常)→ fallback 用 `{cid}.png`(假設 PNG;典型 inline 都是)

3. **去重**:同一 thread 不同信引用同一 cid(thread quote 累積) → 只在**首次**出現的信下載,後續信只在 markdown 引用既有檔(看路徑是否存在判斷)

4. **計數**:記錄 `inline_count` 供 Step 7 報告 + Step 8 audit。

#### Step 5.5.1: Explicit MIME attachments

(原 Step 5.5 邏輯,不變)

1. **列出附件**：呼叫 `mcp__plugin_che-apple-mail-mcp_mail__list_attachments`（或 `list_attachments_batch`）取得附件清單。若為空 → 跳到下一封(但 Step 5.5.0 inline 仍跑)。

2. **分類每個附件**：用 Step 2 載入的分類規則判斷 `data` 或 `document`：

   ```
   classify(filename):
     lowercase_name = filename.lowercased()
     ext = filename 的副檔名（去掉 `.`）

     # Tier 1: keyword match（先比 data_keywords）
     for kw in data_keywords:
       if lowercase_name contains kw → return "data"
     for kw in document_keywords:
       if lowercase_name contains kw → return "document"

     # Tier 2: extension match
     if ext in data_extensions → return "data"
     if ext in document_extensions → return "document"

     # Tier 3: fallback
     return "document"
   ```

3. **決定目標路徑**：
   - `"data"` → `{data_dir}/{original_filename}`
   - `"document"` → `{documents_dir}/{email_md_stem}/{original_filename}`
   
   其中 `email_md_stem` 是該封信的 Markdown 檔名去掉 `.md`（例如 `2026-04-08_Re--Taxometric-Analysis`）。

4. **下載**：呼叫 `mcp__plugin_che-apple-mail-mcp_mail__save_attachment` 將附件存到目標路徑。
   - 檔名保留原始 bytes（空白、`&`、中日文、emoji 不改）
   - 目標目錄若不存在，先 `mkdir -p`
   - 若 `save_attachment` 失敗，log warning 繼續下一個（不中斷歸檔）

5. **更新 Markdown**：在該封信的 Markdown 中插入 attachment 區塊。

   **放置位置**：簽名（signature）之後、thread quote 之前。
   Thread quote 的辨識 pattern：第一個匹配 `差出人:` / `寄件者:` / `From:` / `On .* wrote:` 的行。
   若沒有 thread quote（原始信件，非回覆），attachment 區塊接在 body 最後。

   **兩個獨立 section**(v2.15.0+,issue #45):若該信同時有 inline + explicit,先 `Inline images:` 後 `Attachments:`;只有一邊則只列該邊;空 thread 全省略。

   **連結格式**：
   ```markdown
   Inline images:
   - ![原始檔名](相對路徑URL編碼)

   Attachments:
   - [原始檔名](相對路徑URL編碼) (大小 KB)
   ```

   `Inline images:` 用 `![]()`(image syntax,markdown viewer 直接渲染),`Attachments:` 用 `[]()`(link syntax,點擊下載)。

   URL 編碼規則（僅用於 Markdown link URL，display text 保留原始）：
   - 空白 → `%20`
   - `&` → `%26`
   - 其餘（含中日文）→ 保留原字元

   範例:
   ```markdown
   Inline images:
   - ![CleanShot 2026-05-07 at 15.44.58@2x.png](attachments/2026-05-07_Re--Solution---Iverson-similarity/inline/CleanShot%202026-05-07%20at%2015.44.58%402x.png)

   Attachments:
   - [Figures & Tables20260408.docx](attachments/2026-04-08_Re--Taxometric-Analysis/Figures%20%26%20Tables20260408.docx) (93 KB)
   - [raw_indicators.csv](../../data/raw/raw_indicators.csv) (12 KB)
   ```

6. **回覆信無附件但引用原信附件時**：若 `list_attachments` 為空，但 body 中出現 `<filename.ext>` 形式的引用標記（Mail.app 的 quote-time marker），插入 cross-reference：

   ```markdown
   Attachments:
   (Attachments on the original email from {original_sender} — see `{original_stem}.md`)
   ```

   若無法推斷原始 stem（原信未歸檔），改為：
   ```markdown
   (Attachments referenced in thread quote — original not yet archived)
   ```

7. **累計計數**：記錄 `data_count`、`document_count`、`inline_count`(v2.15.0+) 供 Step 7 報告用。

#### Step 5.5.5: Inline cid: download fallback (v2.15.0+, issue #45)

若 Step 5.5.0 的 `save_attachment(inline_filename)` 失敗(binary 不支援 inline name 或 inline cid: 不在 binary 的 attachment list),**不**完全 skip — 改寫 cross-reference 註記:

```markdown
Inline images:
- (cid:331ECED2 — CleanShot 2026-05-07 at 15.44.58@2x.png — binary 無法 download by name;見 Mail.app 原始信)
```

User 看到註記知道 inline 圖存在但需手動 export from Mail.app。Filed 上游 issue 在 PsychQuant/che-apple-mail-mcp 跟進 binary-side support。

### Step 5.7: 維護 `threads.json`（v2.6.0+,路徑 v2.8.0+ 改 `${THREADS_FILE}`）

每封新歸檔的 md 寫出後,同步更新 `${THREADS_FILE}` (`.claude/.mail/state/archives/${SLUG}/threads.json`):

**格式**：

```json
{
  "version": "1.0",
  "last_updated": "2026-04-22T15:01:09Z",
  "threads": {
    "SE manuscript 10xx-2025": {
      "messages": [
        {
          "message_id": "<7F43E052-EA1B-432D-AF0C-64F0CDBD8B32@ntu.edu.tw>",
          "file": "2026-01-28_Re--SE-manuscript-10xx-2025.md",
          "date": "2026-01-28T08:00:24Z",
          "sender": "d06227105@ntu.edu.tw",
          "in_reply_to": "<eddba65d53754587aeee5d86ff631d2c@ntu.edu.tw>"
        }
      ],
      "participants": ["yfhsu@ntu.edu.tw", "d06227105@ntu.edu.tw", "d11227103@ntu.edu.tw"],
      "first_message": "2025-12-19T06:19:30Z",
      "last_message": "2026-01-28T08:00:24Z",
      "message_count": 1
    }
  }
}
```

**更新演算法**（對每封新歸檔的信）：

1. 從 md frontmatter 讀 `thread_key`
2. 若 `.threads.json` 裡沒有此 thread_key，建立新 entry：
   ```
   {"messages": [], "participants": [], "first_message": null, "last_message": null, "message_count": 0}
   ```
3. 在 `messages` 陣列**尾端** append 新 message（保持時間序；若日期早於 last_message，可插入正確位置，但一般 append 即可）
4. 更新 `participants` 集合（加入 sender + to + cc 的 email，去重）
   > **來源（batch 與 per-email 皆同）**：`sender` 取自 md frontmatter；`to`／`cc` 取自 md **本文的 `To:`／`Cc:` header 行**（frontmatter 只帶 `sender`，不帶 to/cc）。batch 工具（Step 5.0）與 per-email（Step 5.1）都寫出相同的 `To:`／`Cc:` body header，故本步 file-driven、source-agnostic，兩路徑一致——不需針對 batch 另設 participant 來源。
5. 更新 `first_message` = `min(first_message, new.date)`，`last_message` = `max(last_message, new.date)`
6. `message_count += 1`
7. 更新頂層 `last_updated` 為目前時間

**Append-only 原則**：此索引只做新增，不修改、不刪除既有 entry。若 thread 需要分割或合併，用 `/archive-mail-rebuild-threads` 重建。

**同 thread 不同時段的處理**：若 bare subject 相同但兩組訊息時間相差 > 90 天，**仍歸在同一 thread**（因為我們尊重使用者的 subject 選擇）。若要拆分，使用者需手動改 md frontmatter 的 `thread_key`（例如加 `-2026` 後綴），然後跑 rebuild。

### Step 6: 更新 Message-ID 索引

將新歸檔的郵件加入 `${INDEX_FILE}` (`.claude/.mail/state/archives/${SLUG}/email_index.json`):

```json
{
  "version": "1.0",
  "last_updated": "YYYY-MM-DD",
  "emails": {
    "message-id@example.com": {
      "file": "2026-01-13_Meeting-notes.md",
      "date": "2026-01-13 14:30",
      "subject": "郵件主旨",
      "thread_key": "Meeting notes"
    }
  }
}
```

v2.6.0+ 在每個 email entry 多記一個 `thread_key`，方便反向查詢。

> **`last_updated` 語意（mail#261）**：email_index.json 的頂層 `last_updated` = 所有 entry 的 **max(date)**（語料最新歸檔日，非執行日）——與 threads.json（Step 5.7）用**目前時間**不同，兩者刻意分工：前者答「語料多新」，後者答「索引多新」。**計算一律經 Step 8.5 的 robust `to_ymd()` 正規化（mail#275）**——entry date 可能混入 RFC822，直接 `[:10]` 字典序比較會選出無效值；本 step 與 Step 8.5 兩處計算必須同一規則。

> **原子寫入（plugins#110，partial-write-safe）**：寫 `${INDEX_FILE}` **一律 temp+rename**——先寫 `${INDEX_FILE}.tmp`（完整 JSON），再 `os.replace(tmp, INDEX_FILE)`（同檔系統的 atomic rename）。中斷（agent abort / 寫到一半失敗）只會留下半寫的 `.tmp`（下次覆寫），**絕不**讓 `${INDEX_FILE}` 本身變成半寫/損壞的 JSON。這是 #261 diagnosis「先解有 gate、durable fix 待補」的根治，針對的威脅是 **interrupted/partial write**；**嚴格 power-fail durability** 另需 `fsync(檔案)+fsync(目錄)`（本 SOP 威脅模型不含斷電，故不強制，但要斷電安全時可加）。Step 8.5 reconcile gate 擋的是 cross-file 孤兒（md 有、index 無 entry），原子寫入擋的是 single-file partial-write 損壞——兩者互補。Step 6 與 Step 8.5 的 index 寫入都走此路徑。

### Step 7: 輸出報告

```
═══════════════════════════════════════════
Archive Mail 完成
═══════════════════════════════════════════

過濾條件: user@example.com
輸出目錄: communication/emails

新歸檔: 5 封
  - 2026-01-13_Meeting-request.md
  - 2026-01-12_Report-feedback.md
  - ...

跳過（已歸檔）: 12 封

Thread 索引: 2 new threads, 3 existing threads updated
  - "Meeting notes": 3 new messages (total 5)
  - "Report feedback": 2 new messages (total 2, new thread)

附件: 15 個下載
  → 4 to data/raw
  → 11 to correspondence/attachments
  → 2 inline images to correspondence/attachments/{stem}/inline/  (v2.15.0+, #45)

═══════════════════════════════════════════
```

若無附件：`附件: 0 個下載`(不顯示分類明細)。
若無 inline images,省略該行(v2.15.0+ 新加,只在有 inline 時顯示)。
Thread 索引行（v2.6.0+）：永遠顯示，即使沒新 thread。

### Step 8: 覆蓋率稽核（Coverage Audit）（v2.4.0+）

歸檔主流程結束後，自動執行覆蓋率稽核：

**8a. 附件完整性檢查**：

對所有新歸檔的郵件,**分兩部分檢查**(v2.15.0+, #45):

**8a.1 Explicit attachments**:呼叫 `list_attachments` 取得 explicit MIME attachment 數量,比對磁碟上對應目錄的實際檔案數,**並對每個磁碟檔案 stat 大小（mail#314——count 相符但檔案 0 bytes 的靜默失敗曾 11 週未被偵測）**。

- 數量一致且全部 > 0 bytes → pass
- 數量不一致 → 發出 warning：`⚠️ {email_stem}: {差異} explicit attachment missing (expected {報告數}, found {磁碟數})`
- **任一檔案 0 bytes → 發出 warning：`⚠️ {email_stem}/{filename}: 0-byte attachment (download appears to have failed silently)`**——與數量 warning 並存,不互相取代。0-byte 檔的重新下載:對該 id 重跑 `save_attachment`(server 端 mail#314 修復後,0-byte 寫入會直接回錯誤而非假成功,並在成功時回報 `(N bytes)`)

**8a.2 Inline cid: images** (v2.15.0+):從 HTML body 解析 inline cid: 引用數量,比對 `{stem}/inline/` 目錄實際檔案數。

- 一致 → pass
- 不一致(已 cross-reference 註記取代下載)→ 發出 warning:`⚠️ {email_stem}: {N} inline images cross-referenced (binary download unsupported); see Mail.app for visual content`
- 完全 miss(連 cross-reference 都沒)→ `⚠️ {email_stem}: {N} inline images parsed from body but not handled (skill bug, file follow-up)`
- **已下載的 inline 檔案同樣 stat 大小,0 bytes → `⚠️ {email_stem}/inline/{filename}: 0-byte inline image` (mail#314)**

**8b. Thread 完整性檢查**：

對歸檔中每個唯一的 bare subject：
1. 用 bare subject 搜尋，同時取回每筆 `mailbox`（套 drop-set 用）並在伺服器端做邏輯去重（對齊分子的 Message-ID 去重基礎）：
   `search_emails(field: "subject", query: bare_subject, projection: "summary", dedup: "logical", limit: N)`
   —— **必須 `projection: "summary"`**（唯一同時回 `mailbox` 又支援 `dedup` 的 projection：`count` 無 row 無法套 drop-set、`full` 不支援 `dedup`，plugins#208）；**`dedup: "logical"`** 在伺服器端塌陷同一封信的多匣副本（Gmail INBOX + 全部郵件 等）——否則含 dual-stored 的信會被重複計數，即使**零草稿**也 `archived < total` 每次誤報（plugins#112 的真正根因，不只是草稿）。`N` 取遠大於該 subject 預期兄弟數（**預設 limit 僅 50，通常不足**）。`dedup: logical` 依 (subject, sender, date_received) 分組，是分子 Message-ID 基礎的**近似**（勿宣稱逐 Message-ID 對等）。誠實揭露方向：此粗粒度 dedup 對 completeness 稽核偏「**少算**」而非「多算」——極罕見情形下兩封**真正不同**的信共用相同 subject+sender+同秒收信時戳會塌成一筆，若其中一封正是缺失的兄弟，`archived < total` 就不觸發而**漏報**（不是誤報）。正常郵件流下此三元組完全碰撞機率可忽略，且 `search_emails` 無 Message-ID 級 dedup，此為工具限制、非本步引入。
2. **對結果每筆的 `mailbox` 套用 Step 3 的統一 drop-set**（丟 Drafts / Trash 實名 + `exclude_mailboxes`，比對規則見 Step 3 的 `matchesSpecial`，**勿裸 `==`**），數過濾後的存活筆數為 total —— 分子（已歸檔 count）已經 Step 3 Message-ID 去重且排除草稿/垃圾桶；分母同時經 `dedup: logical` 去重（步驟 1）＋ drop-set 排除（本步），兩邊才同基礎。
   > **實作註（drop-set 套在代表匣上）**：`dedup: logical` 去重後每筆只剩一個代表 `mailbox`，drop-set 即套在該代表匣。此在 Gmail 模型下安全——dual-storage 對（INBOX/全部郵件、寄件備份/全部郵件）全是**非 drop** 匣，而 Drafts/Trash 副本因 sender/date 不同不會與收件塌成同一筆，故代表匣不會誤把該保留的信丟掉。非 Gmail provider 若存在「同一信橫跨 kept + dropped 匣」的儲存模型，需另行驗證代表匣選取不會漏丟。
3. **檢查步驟 1 回傳的 `truncated`**：若 `truncated: true`（配對數超過 `limit`），過濾後的頁面只是**被截斷的一頁**，**不得**當成完整分母 —— 據此比對會把「其實缺兄弟」誤判成 complete（false-negative，比誤報更糟，因為它**靜默隱藏真正的缺口**）。改提高 `limit` 重取直到 `truncated: false`；若仍無法取全，發出 `⚠️ Thread "{subject}": 稽核分母被截斷（配對數 > limit），無法證明完整`，並**略過**此 thread 的 archived/total 比對（不得回報 complete）。
4. `truncated: false` 時比對已歸檔的 count：若 `archived < total` → 發出 warning：`⚠️ Thread "{subject}": {差額} potential missing siblings (archived {已歸檔}/{total})`

**8c. 稽核報告**：

```
Archive Coverage Audit
═══════════════════════════════════════════
附件覆蓋: explicit 15/15 + inline 2/3 (1 cross-ref'd) (94%)
Thread 覆蓋: 3 threads, 2 complete, 1 with gaps

搜尋結果: 37 by sender + 14 by recipient/sent + 12 by subject + 9 by thread expansion = 58 unique

Issues:
  ⚠️ 2026-04-08_Re--Taxometric: 1 attachment missing
  ⚠️ 2026-03-12_Re--Draft/manuscript.docx: 0-byte attachment (silent download failure)
  ⚠️ 2026-05-07_Re--Solution: 1 inline image cross-referenced (binary unsupported)
  ⚠️ Thread "indicator selection": 2 potential missing siblings

建議: 在 .claude/.mail/config.md 加入 subject_keywords 擴大搜尋範圍
═══════════════════════════════════════════
```

若所有檢查通過：
```
Archive Coverage Audit
═══════════════════════════════════════════
附件覆蓋: explicit 15/15 + inline 3/3 (100%) ✓
Thread 覆蓋: 3 threads, 3 complete ✓
═══════════════════════════════════════════
```

若無 inline,簡化:`附件覆蓋: 15/15 (100%) ✓`(同 v2.14.0 ↓ 行為)。

### Step 8.5: End-of-run Index Reconcile Gate（強制，mail#261）

> **使用者原話**：「可能有些有歸檔但是 index 沒更新……最後一件事情是要更新 index」。
> 寫 md 與 append index 非原子——中斷/跳步會留下「md 已寫、index 無 entry」的孤兒（實測 86/135），dedup 隨即失效。本 gate 是 run 的**最後一件事**，未通過前 run 不得宣告成功。

執行分**兩 phase**：先 Phase 0 用**本 run 的 manifest**機械化補齊本次 batch 寫入（乾淨、零 heuristic），再 Phase 1 對 `${output_dir}` 全量掃描收斂**歷史孤兒**（前一 run 中斷、非 batch、外部放入的 md——這些的 manifest 已不在記憶體，只能從磁碟 frontmatter 重建）。

**Phase 0：manifest-driven（plugins#110，僅本 run 的 Step 5.0 batch 寫入）**

若本 run 走了 Step 5.0 batch 路徑、manifest 仍在記憶體：對每個 `status:"written"` item，**三源合併**補齊 index entry（`message_id` 已在 `${INDEX_FILE}` keys 則跳過、算 `verified`）：
- `file` = manifest item 的 `written_path` basename（**權威**，非猜檔名）
- key `message_id` = item 的 `message_id`（**權威**，免重讀 frontmatter；`status:"written"` item 必帶）
- `date` / `thread_key` = 讀該 `written_path` md 的 **frontmatter**（工具已寫入這兩個 frozen 欄位；乾淨、結構化——與 Phase 1 的 `date` 來源一致，且免依賴 preview 存活）
- `subject` = **Step 4.5 preview** 的 `id→subject`（frontmatter **無** subject，只有 body `Subject:` 行——preview 是唯一乾淨來源；若 preview slice 未保留 → fallback 讀 body `Subject:` 行，非寫空 subject）

→ 本 run 的 index entry 機械化、`subject` 儘量零 heuristic（僅 preview 遺失才退回 body-line）。Phase 0 補的 message_id 記入一個 set，Phase 1 掃到同 message_id 直接算 `verified`、不重複處理。

> **「無 manifest」的兩種情形要區分（不可一律靜默降級）**：(a) 本 run **全走 Step 5.1 fallback**（< 5 封 / enriched / 無 batch）→ 本就沒有 manifest，Phase 0 空跑、直接進 Phase 1，**正常**。(b) 本 run **確實跑過 Step 5.0 batch**、卻取不到 manifest → 這違反 Step 5.0「manifest 必須留存」的契約（#107），**必須在摘要標 ⚠「batch ran but manifest lost — reconcile degraded to Phase 1 heuristic」**，不得當成 (a) 靜默吞掉。兩者 index 完整性都由 Phase 1 兜底（batch md 會被當歷史孤兒補齊），差別只在 (b) 的 subject 退回 body-line heuristic 且揭露契約違反。

**Phase 1：full-scan fallback（歷史孤兒 + 非 manifest 來源）**

1. 對每個 `${output_dir}/*.md`（**僅頂層 glob**，不深入子目錄、不追 Step 2.1 的 symlink 兄弟歸檔——那些只是 read-only 去重來源，絕不寫進本 index）：讀 frontmatter `message_id`。
   - message_id 已在 Phase 0 set 或 `${INDEX_FILE}` keys → `verified` +1（不重複補寫）。
   - **`message_id` 匹配 `^synthetic:`（mail#319）→ 記入獨立的 `synthetic_placeholder` 清單**（列檔名報告，不 `verified` 不 `repaired` 不補寫 index）——synthetic key 是過去 session 發明的假 unique key，對 dedup 結構性不可見（每次執行產生不同 timestamp），把它當合法 key 收進 index 只會固化重複。修復走 `/archive-mail-repair-synthetic-ids`。
   - 無 frontmatter / 無 `message_id` / `message_id_missing: true` → 記入 `unparseable` 清單（列檔名報告，不修改該檔）。
   - **不在** → 孤兒：**就地補寫 index entry**（append-only），`repaired` +1。補寫的 entry **必須符合 Step 6 的 canonical schema** `{file, date, subject, thread_key}`：`file` = 掃描到的 md 檔名（basename，**必填**）；`date` / `thread_key` 取自 frontmatter——**`date` 若非 ISO 開頭**（如 RFC822 原樣，見 Step 5.1 enforcement）**先以 `email.utils.parsedate_to_datetime(raw).isoformat()` 正規化再寫入 entry**（parse 失敗比照揭露紀律列於摘要、寫原樣不阻斷；mail#275——孤兒補寫是歷史 RFC822 汙染收斂進 ISO 的機會點）；`subject` 從 md 本文的 `Subject:` 行抽取（抽不到 → 填空字串並在摘要揭露）——**此 heuristic 僅 Phase 1 用**（Phase 0 有 preview 的乾淨 subject）。**若 frontmatter 有 `message_id` 但缺 `date` 或 `thread_key`**（罕見——archive-mail 寫的 frontmatter 一律帶這兩欄；只可能是外部/損毀 md）：比照 subject-miss 的「揭露而非靜默」紀律（惟 date/thread_key **無** subject 那種 body-line fallback，缺就是缺），缺的欄位填空字串並在摘要揭露該檔欄位不全，**不得靜默寫 null**。frontmatter 的 `sender` / `direction` **不寫入** entry（非 email_index 欄位）。摘要須揭露 repaired 列為重建而來。
2. Phase 0 + Phase 1 都補完後，`last_updated` 更新為 index 內所有 entry 的 **max(date)**（不是今天——反映語料實況）。**比較與寫入必須先做 robust 日期正規化（mail#275）——絕不可直接 `date[:10]` 字典序比較**：entry 的 date 實務上混雜三種格式——`2026-01-13 14:30`、ISO `T`、以及 **RFC822**（`Thu, 25 Jun 2026 09:30:45 +0800 (CST)`，見 Step 5.1 的正規化漏洞）。RFC822 開頭是星期縮寫，`[:10]` 切片後（`Thu, 25 Ju`）首字母字典序恆大於數字，任何一筆 RFC822 entry 都會贏過全部 ISO entry，`last_updated` 被寫成 `Wed, 01 Ju` 類無效值（mail#275 實證）。正規化參考實作（`^\d{4}-\d{2}-\d{2}` 快篩 ISO 取前 10 字；其餘走 `email.utils.parsedate_to_datetime`；parse 失敗回 None、**排除於 max 之外並在 reconcile 摘要揭露**，不靜默）：

   ```python
   import re
   from email.utils import parsedate_to_datetime
   def to_ymd(s):
       s = (s or "").strip()
       if re.match(r'^\d{4}-\d{2}-\d{2}', s):
           return s[:10]
       try:
           return parsedate_to_datetime(s).date().isoformat()
       except Exception:
           return None
   mx = max((y for y in (to_ymd(v.get("date","")) for v in emails.values()) if y), default="")
   ```

   **寫回 `${INDEX_FILE}` 走 temp+rename 原子寫入**（見 Step 6 的原子寫入 note）——本 gate 一次補多筆，中斷不得留半寫 index。
3. `${THREADS_FILE}` **不在本 gate 內逐孤兒補寫**（frontmatter 沒有 to/cc，無法重建 Step 5.7 要求的 `participants`；threads.json 的規則在 Step 5.7、不是 Step 6）。**Phase 0 新增任一 entry OR Phase 1 `repaired > 0`** 時，改跑 `/archive-mail-rebuild-threads` 從 md 全量重建 threads.json——Phase 0 的機械化補齊同樣是 index 新增，若只看 Phase 1 的 `repaired` 會漏掉「Phase 0 補了 entry 但 Step 5.7 那步被中斷」的 thread-view 過時（happy path 下 Step 5.7 已為 batch md 更新 threads.json，此僅防雙重中斷）。
4. 輸出一行摘要並附在歸檔報告末尾（首跑常見 unparseable > 0——歷史檔常無 frontmatter，這是預期輸出、不是失敗）。摘要區分 Phase 0（manifest 機械化）與 Phase 1（磁碟重建）：

```
Index Reconcile: Phase 0 manifest 12 written（乾淨補齊）; Phase 1 135 md 掃描 — 61 verified（含 Phase 0 補的 12）, 66 repaired（heuristic subject）, 8 unparseable ⚠（列出 8 檔）, 3 synthetic_placeholder ⚠（mail#319，列出檔名；跑 /archive-mail-repair-synthetic-ids）
```

5. `unparseable > 0` → 摘要標 ⚠ 並列出檔名，**不得靜默**；由 user 決定補 frontmatter 或排除。**這不使 run 失敗**——會失敗的是跳過本 gate 或靜默吞掉清單。
6. 全部完成後才 `TaskUpdate reconcile_index → completed`。**跳過本步 = run 失敗**。

## 注意事項

- 使用 apple-mail MCP，需確保 MCP server 已連接
- Message-ID 用於去重，確保不會重複歸檔
- **既有歸檔的一次性 0-byte 掃描（mail#314 remediation）**：`find <documents_dir> <data_dir> -type f -size 0` — 首次升級到本版後跑一次,列出的檔案逐一重新 `save_attachment`
- 寄出的郵件不產生「重點摘要」和「待辦事項」
- **附件自動下載**（v2.3.0+）：每封歸檔信件的附件會自動下載到分類目錄。研究資料檔（csv / sav / xlsx 等）放到 `data/raw/`；文件附件（pdf / docx 等）放到 `correspondence/attachments/{email_stem}/`。可透過 `.claude/emails.md` 的 `attachment_routing` 區塊自訂規則。
- **搜尋擴展 + 覆蓋率稽核**（v2.4.0+）：除了 sender 搜尋，可設定 `subject_keywords` 補抓 internal threads。每次歸檔後自動跑 Coverage Audit 檢查附件完整性和 thread 覆蓋率。
- **Thread 索引**（v2.6.0+）：歸檔時自動維護 `.threads.json`，記錄每個 thread 包含哪些 messages、參與者、時間範圍。每封 md 的 YAML frontmatter 也帶有 `thread_key` / `in_reply_to`，為 canonical truth。搭配 `/archive-mail-view <thread_key>` 生成聚合 thread 視圖，`/archive-mail-rebuild-threads` 從 md 重建索引。

## 附件分類設定範例

在 `.claude/emails.md` front matter 加入 `attachment_routing` 覆寫預設規則。**注意：partial override 取代所有預設**——省略的欄位會變成空列表，不會自動使用內建預設。

完整預設值（供 copy-paste）：

```yaml
---
filters:
  - tatsuma
attachment_routing:
  data_extensions: [csv, tsv, sav, dta, parquet, feather, xlsx, sas7bdat]
  document_extensions: [pdf, docx, doc, txt, md, rtf, odt]
  data_keywords: [data, raw, indicators, codebook, dataset]
  document_keywords: [Submission, Figures, Tables, Manuscript, draft, Revision, v1, v2, v3]
  data_dir: data/raw
  documents_dir: correspondence/attachments
---
```

只需列出想改的部分（但理解：列出即取代整組預設）：

```yaml
---
attachment_routing:
  data_extensions: [csv, sav]            # 只認這兩種為 data
  data_keywords: [raw, indicators]       # 窄化 keyword
  data_dir: research/raw-data            # 自訂 data 目標路徑
  documents_dir: correspondence/attachments  # 保留預設
---
```

## 搜尋擴展設定範例（v2.4.0+）

```yaml
---
filters:
  - tatsuma
subject_keywords:                        # 用 subject 關鍵字補抓 internal threads
  - taxometric
  - SSQ
  - "attachment security"
participant_aliases:                     # 成員別名（audit 報告顯示用）
  "b08801008@ntu.edu.tw": "Pei-Chi"
  "kllay@ntu.edu.tw": "Lay"
attachment_routing:
  data_dir: data/raw
  documents_dir: correspondence/attachments
---
```

設定 `subject_keywords` 後，Step 3 會自動做三輪搜尋（sender + subject keyword + thread-subject expansion）並去重。Step 8 Coverage Audit 會報告覆蓋率。

## Corpus refinement 設定範例(v2.20.0+, two-layer model)

Two-layer model — `filters` (search-time) vs `*_includes` (post-fetch restriction) 的具體用法:`filters` 把寬網撒到 Mail.app(Step 3 MCP query),refinement 在 fetch 完之後縮窄到只關心的 sender / recipient / subject(Step 4.0 thread-level)。

**範例 1**:對中研院 email 設 OR-search(三個 email 任一命中即拉),但要排除誤命中的補習班信件(#84)和訂閱噪音:

```yaml
filters:                              # Layer 1 search-time corpus 定義
  - che830621@as.edu.tw
  - che830621@gate.sinica.edu.tw
  - che830621@stat.sinica.edu.tw

recipient_excludes:                   # Layer 2 post-fetch: drop 寄到補習班的信(整 thread)
  - EDUCATION5361@yahoo.com.tw

subject_excludes:                     # Layer 2 post-fetch: drop 訂閱確認 noise
  - 訂閱確認信
  - 取得官方
```

**範例 2**:`filters` 撒寬,`sender_includes` 在 fetch 後再縮窄到某域名(#84 use case for narrowing collaborator scope):

```yaml
filters:
  - yfhsu                             # 任何提到 yfhsu 的信都先拉進來
sender_includes:                      # ...但 fetch 後只保留 sender 含 @gate.sinica 的
  - "@gate.sinica.edu.tw"
```

**範例 3**:workspace 按 topic scoping(#76 use case),只歸檔 subject 命中關鍵字的 thread:

```yaml
filters:
  - yfhsu
subject_includes:                     # whitelist: 只保留 bare subject 含這些字串的 thread
  - affine
  - Iverson
  - similarity
```

關鍵語意(完整契約見 spec `openspec/specs/archive-mail-corpus-refinement/spec.md`):

- 6 個欄位全為 opt-in。unset 或空 list 都 = no refinement on that axis(100% backward compat)
- **Case-insensitive substring match**:sender / recipient 比對 bare email(strip display name);subject 比對 bare subject(strip 前綴 `Re:` / `RE:` / `Fwd:` / `FW:` / `转发:` / `轉寄:`)
- **同軸 includes + excludes 同設**:excludes win(blacklist 優先 — `sender_includes` 命中但 `sender_excludes` 也命中 → drop)
- **Per-thread coherence**:thread 內任一 message 命中 → 整 thread keep / drop。Trap:thread 中某 message 不小心 CC 到被 exclude 的地址會拖整個 thread 下水。
- **Refinement 在 dedup 之前**:被排除的 thread Message-ID 不會進 `email_index.json`,後續 run 仍會 drop 同一批 thread,不會 re-surface 為 new。
