# /archive-mail-repair-synthetic-ids — 修復 synthetic message_id 佔位符（一次性，mail#319）

掃描歸檔目錄中 `message_id` 匹配 `^synthetic:` 的 markdown 檔，嘗試從 Mail 重新解析**真實** RFC 5322 Message-ID 並就地修復 frontmatter + `email_index.json`。**保守優先：寧可留 unparseable 交人工，絕不錯誤合併兩封不同的信。**

## 背景（為什麼存在）

過去某些 session 在拿不到真 Message-ID 時即興發明了 `synthetic:<ISO-timestamp>` 佔位符（SOP 當時對缺值**沒有規定**——現已明文禁止，見 archive-mail frontmatter 規則）。synthetic key 的 timestamp 是**執行當下**時間，同一封信每次重跑產生不同 key → dedup 結構性失效：mail#319 實測單一 target 84/273 檔帶 synthetic key、單輪 12 封靜默重複、所有既有 gate 全綠。

## 用法

```
/archive-mail-repair-synthetic-ids <archive_target 或 output_dir>
```

## Execution

### Step 0: Bootstrap Task List（強制）

```
TaskCreate(name="scan_synthetic", description="glob 頂層 *.md，抓 frontmatter message_id 匹配 ^synthetic: 的清單")
TaskCreate(name="rekey_attempts", description="逐檔嘗試從 Mail 重新定位真 Message-ID（保守匹配，見下）")
TaskCreate(name="apply_repairs", description="可修者：改寫 frontmatter message_id + email_index.json 換 key（temp+rename 原子寫）")
TaskCreate(name="dedupe_pass", description="re-key 後同一真 Message-ID 對到多檔 → 內容比對確認重複 → 保留最早、其餘移 duplicates/ 子目錄（不刪）")
TaskCreate(name="report", description="修復報告：repaired / still-unparseable / duplicates-quarantined 三清單")
```

### Step 1: 掃描

僅頂層 `*.md`（同 Step 8.5 紀律，不深入子目錄）。抓 frontmatter `message_id` 匹配 `^synthetic:` 者，連同其 `date`、`thread_key`、`sender`、body `Subject:` 行入清單。

### Step 2: 重新定位真 Message-ID（保守階梯）

對每檔依序嘗試，**第一個成功即停**：

1. **Subject 精確搜尋**：`search_emails(field: "subject", query: <bare subject>, projection: "summary", dedup: "logical")` → 候選中 **sender 相同且 date 相差 < 2 分鐘** 者恰好一封 → 用該 id 呼叫 `get_email_headers` 取真 Message-ID。
2. 候選為零或多於一封（含同 thread 密集時間戳的情形）→ **不猜**。記入 `still-unparseable`。

> mail#319 issue 作者自證：ad-hoc `(sender, bare_subject, ±時間窗)` 三元組在密集 thread 中不可靠——所以匹配窗刻意窄（2 分鐘、恰好一封），寬鬆匹配寧可失敗。

### Step 3: 修復

- frontmatter：`message_id: "synthetic:…"` → `message_id: "<真值>"`（原檔就地改寫）。
- `email_index.json`：舊 synthetic key 的 entry 換 key 為真 Message-ID（**temp+rename 原子寫**，同 Step 8.5 紀律）。
- 順帶修 date offset（mail#319 secondary defect）：該檔 `date` 無 offset 時，用 `get_email_headers` 的 Date header 重寫為帶 offset 的 ISO。

### Step 4: 事後去重

re-key 後若兩檔對到**同一**真 Message-ID（synthetic 重複的實體化）：內容比對（body 前 500 字）確認語意重複 → 保留檔名日期最早者，其餘**移入 `duplicates/` 子目錄**（不刪除——人工確認後自行清理），index 只留存留檔的 entry。

### Step 5: 報告

```
Synthetic-ID Repair Report
═══════════════════════════════
scanned: 273 md — 84 synthetic
repaired: 61（frontmatter + index re-keyed）
still-unparameterizable: 19 ⚠（原信已不在 Mail / 匹配不唯一——列出檔名，交人工）
duplicates quarantined: 12 → duplicates/（列出對應）
```

跑完後建議接 `/archive-mail-rebuild-threads`（index key 大量變動，threads.json 需全量重算）。

## 鐵律

- **絕不寬鬆匹配**：候選不唯一就是 unparseable。錯誤合併兩封不同的信是不可逆的資料損毀；留佔位符只是持續的已知缺陷。
- **絕不刪檔**：重複只隔離到 `duplicates/`。
- **原信已從 Mail 刪除者修不了**——如實列出，這是本工具的誠實邊界。
