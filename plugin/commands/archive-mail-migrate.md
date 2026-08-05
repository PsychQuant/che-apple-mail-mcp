---
description: 一次性把所有舊 archive 的 indices + config 搬到 .claude/.mail/ namespace
argument-hint: [--dry-run]
allowed-tools: Read, Write, Glob, Bash(mkdir:*, mv:*, find:*)
---

# Archive Mail — Migrate to `.claude/.mail/` Namespace（v2.8.0+）

把散在各個 archive directory 的 `.email_index.json`、`.threads.json`,以及 `.claude/emails.md`,集中搬到 `.claude/.mail/` namespace。學 IDD `.claude/.idd/` 的 namespace 收斂 pattern。

## 為什麼要 migrate

v2.8.0 之前的 file layout:

```
{cwd}/
├── .claude/
│   └── emails.md                  ← config 散在 root
└── communications/emails/
    ├── .email_index.json          ← state 散在 archive output 裡
    ├── .threads.json
    ├── 2026-01-13_xxx.md          ← archive markdown(不動)
    └── ...
```

v2.8.0+ 集中後:

```
{cwd}/
├── .claude/.mail/
│   ├── config.yaml                ← 從 .claude/emails.md 搬來(v2.7.0 ↓);v2.16.0+ 副檔名 .yaml
│   └── state/
│       └── archives/
│           └── communications-emails/
│               ├── email_index.json   ← 從 communications/emails/.email_index.json 搬來
│               └── threads.json       ← 從 communications/emails/.threads.json 搬來
└── communications/emails/
    ├── 2026-01-13_xxx.md          ← archive markdown 不動
    └── ...
```

`archive-mail` v2.8.0+ 會 auto-migrate(每次跑時 silent 移動),但若你有多個 archive target 不想等到下次 archive 才觸發,可以一次跑這個 command 全部搬完。

## 使用方式

```bash
# Dry run(預覽會搬什麼,不實際執行)
/archive-mail-migrate --dry-run

# 實際執行
/archive-mail-migrate
```

## 執行步驟

### Step 1: 解析參數

```bash
DRY_RUN=false
if [ "$1" = "--dry-run" ]; then
  DRY_RUN=true
fi
NAMESPACE_DIR=".claude/.mail"
```

### Step 2: 掃描所有 archive targets

從當前 working directory 開始,找出所有 legacy index files:

```bash
find . -maxdepth 6 -type f \( -name ".email_index.json" -o -name ".threads.json" \) \
  -not -path "*/.claude/.mail/*" \
  -not -path "*/.git/*" \
  -not -path "*/node_modules/*" \
  2>/dev/null
```

對每一個 hit,推斷它所屬的 archive_dir(file 所在的 directory),然後計算 slug。

範例 output:

```
Detected legacy archive targets:

1. ./communications/emails/.email_index.json (18 entries) + .threads.json (6 threads)
   → slug: communications-emails

2. ./projects/X/comms/.email_index.json (12 entries) + .threads.json (4 threads)
   → slug: projects-X-comms

3. (etc.)

Plus:
  ./.claude/emails.md → .claude/.mail/config.yaml
```

### Step 3: 確認 plan(若非 --dry-run)

用 AskUserQuestion 給 user 看完整 plan,確認後才動手:

```
即將執行 {N} 個搬移操作:

  1. ./communications/emails/.email_index.json
     → ./.claude/.mail/state/archives/communications-emails/email_index.json
  2. ./communications/emails/.threads.json
     → ./.claude/.mail/state/archives/communications-emails/threads.json
  3. ./.claude/emails.md
     → ./.claude/.mail/config.yaml
  ...

⚠ 此操作會移動(不是複製)既有檔案。Archive markdown(.md)和 attachments 不動。
確認執行嗎? (y/n)
```

### Step 4: 執行 migration

對每個 target:

```bash
SLUG=$(echo "${archive_dir}" | tr '/' '-' | sed 's/^[-.]*//;s/[-.]*$//')
INDEX_DIR="${NAMESPACE_DIR}/state/archives/${SLUG}"
mkdir -p "${INDEX_DIR}"

# Move email_index.json
if [ -f "${archive_dir}/.email_index.json" ]; then
  mv "${archive_dir}/.email_index.json" "${INDEX_DIR}/email_index.json"
fi

# Move threads.json
if [ -f "${archive_dir}/.threads.json" ]; then
  mv "${archive_dir}/.threads.json" "${INDEX_DIR}/threads.json"
fi

# Move .threads.json.bak.* if any
for bak in "${archive_dir}"/.threads.json.bak.*; do
  [ -f "$bak" ] && mv "$bak" "${INDEX_DIR}/$(basename "$bak" | sed 's/^\.//')"
done
```

對 config(v2.16.0+ #47:`.yaml` first-class,`.md` 視為 legacy):

```bash
mkdir -p "${NAMESPACE_DIR}"

# Step A: legacy .claude/emails.md (v2.7.0 ↓) → namespace .yaml
if [ -f ".claude/emails.md" ] && [ ! -f "${NAMESPACE_DIR}/config.yaml" ] && [ ! -f "${NAMESPACE_DIR}/config.md" ]; then
  mv ".claude/emails.md" "${NAMESPACE_DIR}/config.yaml"
  echo "✓ .claude/emails.md → ${NAMESPACE_DIR}/config.yaml"
fi

# Step B: namespace .md (v2.8.0–v2.15.0) → .yaml (v2.16.0+ #47)
if [ -f "${NAMESPACE_DIR}/config.md" ] && [ ! -f "${NAMESPACE_DIR}/config.yaml" ]; then
  mv "${NAMESPACE_DIR}/config.md" "${NAMESPACE_DIR}/config.yaml"
  echo "✓ ${NAMESPACE_DIR}/config.md → ${NAMESPACE_DIR}/config.yaml"
fi
```

### Step 5: 驗證

對每個 migrated target,跑:

```bash
# Check new file exists
[ -f "${INDEX_DIR}/email_index.json" ] && echo "✓ ${INDEX_DIR}/email_index.json"

# Check JSON valid
python3 -c "import json; json.load(open('${INDEX_DIR}/email_index.json'))" \
  && echo "  JSON valid" \
  || echo "  ⚠ JSON invalid"
```

### Step 6: 輸出報告

```
═══════════════════════════════════════════
Archive Mail — Namespace Migration
═══════════════════════════════════════════

Migrated:
  ✓ communications/emails/.email_index.json → .claude/.mail/state/archives/communications-emails/email_index.json (18 entries)
  ✓ communications/emails/.threads.json → .claude/.mail/state/archives/communications-emails/threads.json (6 threads)
  ✓ .claude/emails.md → .claude/.mail/config.yaml
  ✓ .claude/.mail/config.md → .claude/.mail/config.yaml (v2.16.0+ schema rename, #47)

Total: 3 files moved.

Archive markdown(.md)not touched. Attachments not touched.

Next: archive-mail / view / rebuild-threads 都會用新位置。
═══════════════════════════════════════════
```

## 注意事項

- **Idempotent**:重複跑沒事。已經 migrate 過的檔案會 skip(因為來源不再存在)
- **Dry run 一定要先跑**:確認 detected targets 是預期的,避免不小心 migrate 到錯的目錄(例如別的 plugin 的 `.email_index.json`)
- **Archive markdown 不動**:這個 migration 只動 indices + config,不動 user-visible 的 archive 結果
- **Backup 在哪**:legacy 的 `.threads.json.bak.*` 會一起搬到新位置(保留 audit trail)

## 與相關 command 的關係

| Command | 做什麼 |
|---------|--------|
| `/archive-mail` | 歸檔新郵件,**會 auto-migrate 該 archive_dir 的 indices**(silent) |
| `/archive-mail-view` | 讀新位置 indices 生成 thread view,**也 auto-migrate** |
| `/archive-mail-rebuild-threads` | 從 md 重建 threads.json,**也 auto-migrate** |
| `/archive-mail-migrate` | **本 command** — 一次性 batch migrate 所有 archive targets |
