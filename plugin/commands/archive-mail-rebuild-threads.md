---
description: 從 per-email md 的 frontmatter 重建 .threads.json
argument-hint: [archive-dir]
allowed-tools: Read, Write, Glob, Bash(mkdir:*)
---

# Archive Mail — Rebuild Threads Index

掃描 archive 目錄下所有 md 檔的 YAML frontmatter，從 canonical storage 重建 `.threads.json`。

## 什麼時候用

1. **`.threads.json` 損壞或被刪除**
2. **手動修改過 md frontmatter 的 thread_key**（例如拆分長 thread）
3. **從舊版 archive 升級到 v2.6.0+**（舊 md 沒有 frontmatter，需先 backfill frontmatter 再 rebuild）
4. **想確認 `.threads.json` 和 md 檔一致**（當作 sanity check）

## 使用方式

```
/archive-mail-rebuild-threads
/archive-mail-rebuild-threads communications/emails
```

- 第一個參數（可選）：archive 目錄，預設 `communication/emails`

## 執行步驟

### Step 1: 解析參數

- `archive_dir`: 預設 `communication/emails`

若目錄不存在，報錯退出。

### Step 2: 解析 namespace 路徑 + 備份既有 `threads.json`（v2.8.0+）

```bash
NAMESPACE_DIR=".claude/.mail"
SLUG=$(echo "${archive_dir}" | tr '/' '-' | sed 's/^[-.]*//;s/[-.]*$//')
INDEX_DIR="${NAMESPACE_DIR}/state/archives/${SLUG}"
THREADS_FILE="${INDEX_DIR}/threads.json"

mkdir -p "${INDEX_DIR}"

# Auto-migrate legacy(silent)
if [ ! -f "${THREADS_FILE}" ] && [ -f "${archive_dir}/.threads.json" ]; then
  mv "${archive_dir}/.threads.json" "${THREADS_FILE}"
  echo "🔄 Migrated ${archive_dir}/.threads.json → ${THREADS_FILE}"
fi

# Backup existing threads.json before rebuild
if [ -f "${THREADS_FILE}" ]; then
  cp "${THREADS_FILE}" "${THREADS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
  echo "Backed up existing threads.json"
fi
```

備份不刪舊的,方便回滾。

### Step 3: 掃描所有 md 檔

用 `Glob "${archive_dir}/*.md"` 列出所有歸檔 md。

對每一個 md：

1. `Read` 檔案（只需要前 30 行，frontmatter 一定在這裡面）
2. 解析 YAML frontmatter（位於檔案最前面的 `---` 之間）
3. 提取：
   - `message_id`（必需）
   - `thread_key`（必需）
   - `in_reply_to`（可選）
   - `date`（必需）
   - `sender`（必需）
4. 若 frontmatter 缺失或必需欄位不全：
   - 記錄到 `missing_frontmatter` 清單
   - **不中斷流程**，繼續下一檔

### Step 4: 聚合成 threads 結構

建立新的 threads 物件：

```
new_threads = {}

for each valid md:
    key = md.thread_key
    if key not in new_threads:
        new_threads[key] = {
            "messages": [],
            "participants_set": set(),
            "first_message": null,
            "last_message": null
        }

    entry = new_threads[key]
    entry.messages.append({
        "message_id": md.message_id,
        "file": md.filename,
        "date": md.date,
        "sender": md.sender,
        "in_reply_to": md.in_reply_to or null
    })
    entry.participants_set.add(md.sender)
    if md.to/cc available in frontmatter → add to set
    entry.first_message = min(entry.first_message, md.date)
    entry.last_message = max(entry.last_message, md.date)

# 後處理
for key, entry in new_threads:
    entry.messages.sort(key=lambda m: m.date)  # 時序排序
    entry.message_count = len(entry.messages)
    entry.participants = sorted(list(entry.participants_set))
    del entry.participants_set
```

### Step 5: 寫入新的 `.threads.json`

```json
{
  "version": "1.0",
  "last_updated": "2026-04-22T15:01:09Z",
  "rebuilt_from": "frontmatter_scan",
  "threads": { ... }
}
```

**頂層加 `rebuilt_from` 欄位**，記錄這次是從 frontmatter 重建的（而非 archive-mail 增量維護）。方便區分。

### Step 6: 輸出報告

```
═══════════════════════════════════════════
Rebuild Threads Index
═══════════════════════════════════════════

Archive: communications/
Scanned: 67 md files
Parsed: 65 with valid frontmatter
Skipped: 2 (missing thread_key)

Threads rebuilt: 12
  - "SE manuscript 10xx-2025": 17 messages (2025-12-19 → 2026-01-28)
  - "Biometrika submission BIOMTRKA-25-780": 13 messages (2025-12-19 → 2025-12-24)
  - "JRSS series B Overleaf template": 11 messages (2025-12-24 → 2025-12-25)
  - ...

Backup: .threads.json.bak.20260422_150109

Issues:
  ⚠️ 2024-07-14_Old-email.md: missing frontmatter (legacy md, needs backfill)
  ⚠️ 2024-07-14_Another-old.md: missing thread_key

═══════════════════════════════════════════
```

### Step 7: 比對新舊 index（可選 sanity check）

若舊 `.threads.json` 存在，比對新舊差異：

- 新增的 threads
- 消失的 threads（可能表示 md 被刪除）
- message_count 變化的 threads

報告 summary：

```
Diff from previous .threads.json:
  + 2 new threads (from recent archive)
  - 0 removed threads
  ~ 3 threads with message count changes
```

若有 `-` removed threads，提示使用者檢查是不是誤刪 md。

## Legacy md 的 backfill 策略

舊版 archive（< v2.6.0）的 md 沒有 frontmatter。本 skill 不會自動 backfill，但會列出需要 backfill 的檔案。

使用者可以：

1. **手動加 frontmatter**（最保險）
2. **自動推斷並 backfill**：未來版本可提供 `--backfill` 旗標，從 md 內的 `## 元數據` 表格 + 檔名推斷 frontmatter
3. **接受部分覆蓋**：rebuild 跳過沒 frontmatter 的 md，只用新 md 重建 index（舊 md 就不在 index 裡，但檔案仍在）

## 注意事項

- **不修改 md 檔**：純讀取
- **覆蓋 `.threads.json`**：舊的會先備份
- **等冪**：重複執行結果相同（前提是 md 沒變）
- **跑完後建議 review**：比對 `Threads rebuilt` 數量是否合理

## 與相關 skill 的關係

| Skill | 做什麼 |
|-------|--------|
| `/archive-mail` | 存入 per-email md + 增量維護兩個索引 |
| `/archive-mail-view` | 讀 `.threads.json` 生成聚合視圖 |
| `/archive-mail-rebuild-threads` | **本 skill** — 從 md frontmatter 重建 `.threads.json` |
