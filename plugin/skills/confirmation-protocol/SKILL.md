---
name: confirmation-protocol
description: Foresay-derived confirmation workflow for email operations. Use this skill BEFORE executing archive-mail with vague filters, compose_email (sending mail), delete_email/move_email in bulk, or any operation that touches 5+ emails. Show user a structured preview of "what I understood" before taking action, achieving consensus through dialogue. Skip when the input is unambiguous (specific Message-ID, single mark_read, etc.).
---

# Confirmation Protocol — Email Operations

## 核心原則

**AI 不直接執行,先 show 結構化的「我理解你要的是這樣」讓 user confirm/correct/reject,achieve consensus 後才執行**。

借鑑自 [Foresay](https://github.com/kiki830621/foresay) 的 Confirmation Protocol（該專案 2026-07 前名為 NSQL）。它最初設計給 SQL/data query;這裡 adapt 到 Apple Mail 操作。

## Bootstrap(v2.9.0+ 鐵律,強制)

被 trigger 時(filter 模糊 / bulk operation ≥ 5 / destructive / compose 寄出),**第一個動作就用 `TaskCreate`** 把要跑的 phases 建成 todo list:

```
TaskCreate(subject="confirm_phase1_disambiguation",
           description="Filter 是否模糊?模糊 → 列候選 + AskUserQuestion 選定;明確 → 直接 mark completed。處理完 update。")

TaskCreate(subject="confirm_phase2_search_preview",
           description="Search 結果 ≥ 5 → bulk-operation-preview skill 跑 thread breakdown + false-positive flagging,展示 user;< 5 且無 ⚠⚠ → mark completed。")

TaskCreate(subject="confirm_phase3_operation_confirmation",
           description="展示 side-effect scope (N files written, K attachments, total bytes)。Destructive 加 ⚠ 警告。User AskUserQuestion 答覆(a)確認 (b)排除 false positive (c)改 filter (d)取消。")

TaskCreate(subject="confirm_phase4_execute_or_iterate",
           description="按 user 答覆執行 / 回 Phase 1-3 / abort。Abort 時要明確告訴 user『未做任何 side effect』。")
```

**完成每一個 phase 立即 `TaskUpdate → completed`。靜默 skip = 違規**。即使該 phase 是「可 skip」(明確 filter 跳 Phase 1),也要 `TaskUpdate completed` + 註明 skip 原因(在 description 裡 append),不可只是不做。

**為什麼**:沒 task tracking 時,Claude 容易把 Phase 2 preview 用「應該還好吧」rationalize 掉,直接寫檔。Task 標 incomplete 在 UI 看得見,user 知道有東西被跳。

## 何時觸發

| 觸發條件 | 範例 | 嚴重度 |
|---------|------|--------|
| **Filter ambiguity** | 「陳老師」、「最近的信」、「VIP 寄來的」 | 🔴 必 confirm |
| **Bulk operation** | search 結果 ≥ 5 封 | 🟡 建議 confirm |
| **Destructive** | delete_email、empty Trash、bulk move | 🔴 必 confirm |
| **Compose 寄出** | compose_email、reply_email | 🔴 必 confirm |
| **Outbound side effect** | mark_as_junk、forward_email | 🟡 建議 confirm |

**Skip confirm**(可以直接執行):
- 明確 Message-ID 的 read-only 操作(get_email、list_attachments)
- Single email mark_read/unflag
- 純 search/list(沒有 side effect)

## 4-Phase Workflow

### Phase 1 — Disambiguation(若 filter 模糊)

模糊 filter → 列出可能解讀,讓 user 選:

```
「陳老師」可能對應到多個 contacts:
1. cchen@stat.sinica.edu.tw (陳君厚老師,推薦)
2. scchen@stat.sinica.edu.tw (統計所其他「陳」)
3. 其他同事(請補充)

你要哪一個?
```

詳細 trigger 列表見 `email-search-disambiguation` skill。

### Phase 2 — Search Preview(展示找到的 emails,flag false positives)

Search 後 **不直接 fetch** 全部內容,先 list metadata 給 user 過目:

```
搜尋結果:19 封 emails(by sender + 林助理 + subject 含「陳君厚」)
Threads 分布:

  ✓ [04-29] 新聘博士後研究學者繳交資料 (2 msgs)
  ✓ [04-19] 後續面試報告時間請教 (5 msgs)
  ✓ [03-31] 面試提醒 (1 msg)
  ✓ [03-27] 君厚老師面試時間與地點 (時間異動) (2 msgs)
  ✓ [03-26] 君厚老師面試時間與地點 (2 msgs)
  ✓ [03-18] 應徵博士後研究員(鄭澈) (6 msgs)
  ⚠ [03-15] 應徵資料科學統計合作社... (1 msg, sender=scchen,可能 false positive)

⚠ 1 個 thread 標示為 potential false positive(sender 不符合 cchen)
   要排除嗎?確認歸檔範圍?
```

False-positive detection 詳見 `false-positive-detection.md` rule。

### Phase 3 — Operation Confirmation(展示 side effect 規模)

具體說會建立/修改/刪除什麼:

```
我將執行:
- 歸檔 18 封 emails 到 communications/emails/
- 下載 1 個 attachment (handout.pdf, 76 KB)
- 寫 .email_index.json (18 entries) + .threads.json (6 threads)
- 不修改 Mail.app 內容(read-only operation)

⚠ 此操作會建立約 19 個檔案
確認執行嗎?
```

### Phase 4 — Execute or Iterate

- **User 確認** → 執行
- **User 修正**(「不要 03-15 那封」、「也要把 scchen 那個歸入」) → 更新 plan,重新 Phase 3 confirm
- **User 拒絕** → 重新 Phase 1 理解

## Pipeline-style 表示法(default)

借自 nsql 的 pipeline format。Email operation 用:

```
Mail
  -> filter(sender=X OR recipient=X OR subject contains Y)
  -> sort(date desc)
  -> limit(100)
  -> group(thread_key)
```

讓 user 一眼看出操作鏈。

## Operation format(destructive)

借自 nsql 的 operation format:

```
DELETE on Mail
with sender = "spam@example.com"
affecting 247 emails

⚠ 此操作將影響 247 封 emails
⚠ 此操作無法復原(emails 進 Trash 後 30 天清除)

確認執行嗎?
```

## Response handling

- 「對」/「是」/「OK」 → execute
- 「不對,改成 X」 → update interpretation, re-confirm
- 「排除 Y」 → narrow scope, re-confirm
- 「補充 Z」 → expand scope, re-confirm
- 「算了」/「不要做了」 → abort gracefully

## 為什麼這個 protocol 重要

實際案例(2026-05-01 archive 陳老師信件):用戶說「幫我抓陳老師有關的信」,直接 search → fetch 19 封 → 寫 markdown,**事後**發現 265250 是 false positive(寄給 scchen 不是 cchen),又走一輪 rm + index 修復。

如果有這個 confirmation skill,Phase 2 會 flag 這封並讓 user 排除,完全 prevent false positive round trip。

## 相關文件

- `rules/confirmation-triggers.md` — 何時 confirm、何時 skip
- `rules/false-positive-detection.md` — 偵測 search 結果中的 false positives
- `skills/email-search-disambiguation/SKILL.md` — 模糊 filter 怎麼 disambiguate
- `skills/bulk-operation-preview/SKILL.md` — 大量操作的 preview format
- `core/protocol.yaml` — Foresay Confirmation Protocol spec（https://github.com/kiki830621/foresay）
