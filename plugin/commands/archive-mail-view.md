---
description: 從 .threads.json 生成指定 thread 的聚合視圖
argument-hint: <thread-key-substring> [archive-dir]
allowed-tools: Read, Write, Glob, Bash(mkdir:*)
---

# Archive Mail — Thread View

讀 `.threads.json` + per-email md 檔，聚合成單一 thread 視圖檔。用來把散在多個 md 檔裡的對話串整理成敘事性的一篇。

## 使用方式

```
/archive-mail-view "SE manuscript 10xx-2025"
/archive-mail-view "SE manuscript" communications
/archive-mail-view "SE" communications/emails
```

- 第一個參數：thread key（可以是 substring，會模糊匹配 `.threads.json` 裡的 key）
- 第二個參數（可選）：archive 目錄，預設 `communication/emails`

## 執行步驟

### Step 1: 解析參數

從 `$ARGUMENTS` 取得：
- `thread_query`: 要找的 thread key（必填）
- `archive_dir`: archive 目錄，預設 `communication/emails`

若無參數，提示：

```
Usage: /archive-mail-view <thread-key> [archive-dir]

Try: /archive-mail-view "SE manuscript 10xx-2025"
```

### Step 2: 載入索引（v2.8.0+ 從 `.claude/.mail/state/archives/${SLUG}/`）

```bash
NAMESPACE_DIR=".claude/.mail"
SLUG=$(echo "${archive_dir}" | tr '/' '-' | sed 's/^[-.]*//;s/[-.]*$//')
THREADS_FILE="${NAMESPACE_DIR}/state/archives/${SLUG}/threads.json"

# Auto-migrate from legacy(silent)
if [ ! -f "${THREADS_FILE}" ] && [ -f "${archive_dir}/.threads.json" ]; then
  mkdir -p "$(dirname "${THREADS_FILE}")"
  mv "${archive_dir}/.threads.json" "${THREADS_FILE}"
  echo "🔄 Migrated ${archive_dir}/.threads.json → ${THREADS_FILE}"
fi

[ -f "${THREADS_FILE}" ] || {
  echo "ERROR: ${THREADS_FILE} not found (also no legacy ${archive_dir}/.threads.json)."
  echo "Run /archive-mail first to create the index, or /archive-mail-rebuild-threads to regenerate from existing md files."
  exit 1
}
```

### Step 3: 匹配 thread key

在 `.threads.json` 的 `threads` 物件中用 **case-insensitive substring match** 找符合的 key：

- **0 個匹配**：列出前 20 個可用 thread key 給使用者參考，退出
- **1 個匹配**：使用該 key
- **多個匹配**：列出所有匹配的 thread key（含 message_count、last_message），讓使用者用更具體的 query 重跑

### Step 4: 讀取 messages 並依時序排序

對選定的 thread entry：

1. 從 `messages` 陣列讀取所有 `file` 路徑
2. 依 `date` 欄位排序（asc，最早的在前）
3. 對每個 md 檔：
   - `Read` 該檔
   - 解析 YAML frontmatter 取得 `message_id` / `sender` / `direction` / `date` / `in_reply_to`
   - 提取 `## 信件內容` 到下一個 `---` 之間的 body（**不含 thread quote 尾巴**；thread quote 的辨識 pattern 同 archive-mail Step 5.5：`差出人:` / `寄件者:` / `From:` / `On .* wrote:`）
   - 提取 `## 重點摘要`（若有）
   - 提取 `Attachments:` 區塊（若有）

### Step 5: 生成聚合視圖

輸出到 `${archive_dir}/.threads/{thread_key_sanitized}.md`（預設）或根據使用者參數。

檔名 sanitization：同 archive-mail Step 5 的 subject → filename 規則（標點轉 `-`，截斷至 50 字元等）。

**視圖格式**：

```markdown
# Thread: SE manuscript 10xx-2025

**Messages**: 17
**Participants**: yfhsu@ntu.edu.tw, d06227105@ntu.edu.tw, d11227103@ntu.edu.tw
**Time span**: 2025-12-19 06:19 → 2026-01-28 08:00 (40 days)
**Source**: `.threads.json` + 17 md files

---

## 2025-12-19 14:19 — yfhsu@ntu.edu.tw (received)

**File**: `2025-12-19_SE-manuscript-10xx-2025.md`
**Message-ID**: `<...@ntu.edu.tw>`

Dear All:
我稍為把 10xx-2025 的版本順了一回，順便小改幾個地方。看來有模有樣，只需將 "Numerical Illustration: Asymptotic Behavior in Assessment Data" 章節未完成之處補齊即可投稿。Right?
Best, Hsu

### Attachments
- [main.pdf](../attachments/2025-12-19_SE-manuscript-10xx-2025/main.pdf) (234 KB)

---

## 2025-12-21 21:50 — yfhsu@ntu.edu.tw (received)

**File**: `2025-12-21_RE--SE-manuscript-10xx-2025.md`
**Message-ID**: `<...@ntu.edu.tw>`

CC:
我們先把 10xx-2025 這篇搞定，再處理 BJMSP review.
Best, Hsu

---

## 2025-12-22 15:36 — d06227105@ntu.edu.tw (sent)

**File**: `2025-12-22_RE--SE-manuscript-10xx-2025.md`
**Message-ID**: `<...@ntu.edu.tw>`

To：徐老師與昊紘

關於 Kolva 的文章...
[略]

---

[...依序列出所有 messages...]

---

## Summary

本 thread 共 17 封信，涵蓋 SE paper 手稿從整理到投稿前的討論，主要議題：
- Kolva et al. (2017) 表格標記問題
- Empirical illustration 章節完成
- 是否拆成兩篇投稿
- BJMSP review 的時序安排

**Attachments across thread**: 8 個檔案（列出）

*View generated: YYYY-MM-DD HH:MM*
*Source archive: `{archive_dir}`*
```

**設計重點**：

1. **去 quote**：每則 message 只顯示自己的新文字，不重複 thread 歷史（歷史由時序本身呈現）
2. **附件跨引用**：每則附件連結用相對路徑指向 `../attachments/...`，從 `.threads/` 子目錄回查
3. **可重生成**：view 是 derived 資料，`.threads.json` 或 md 改動後可重跑覆蓋
4. **Summary 區塊**：可選。如果使用者想要，可以呼叫 AI 讀完整 thread 後生成 1-2 段 narrative 摘要

### Step 6: 輸出報告

```
═══════════════════════════════════════════
Thread View Generated
═══════════════════════════════════════════

Thread key: SE manuscript 10xx-2025
Source: 17 messages across 40 days
Output: communications/.threads/SE-manuscript-10xx-2025.md

═══════════════════════════════════════════
```

## 注意事項

- **不修改原始 md 檔**：純讀取，輸出到獨立的 `.threads/` 子目錄
- **重跑覆蓋**：每次執行會覆蓋 output 檔案
- **`.threads/` 不該進 git**：建議 gitignore（這是衍生檔案，canonical 在 per-email md）
- **缺檔處理**：若 `.threads.json` 的 file 指向不存在的 md，log warning 並跳過該 message，繼續處理其他
- **Summary 區塊**：預設不生成。若使用者想要，可加 `--summary` 旗標（未來版本）

## 與相關 skill 的關係

| Skill | 做什麼 |
|-------|--------|
| `/archive-mail` | 存入 per-email md + 維護 `.email_index.json` 和 `.threads.json` |
| `/archive-mail-view` | **本 skill** — 生成 thread 聚合視圖（衍生資料） |
| `/archive-mail-rebuild-threads` | 從 md frontmatter 重建 `.threads.json` |
