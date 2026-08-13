# False-Positive Detection — Search 結果 review 規則

Search 結果可能含有不符合 user 真正意圖的 emails(false positives),例如 subject keyword 撞名。Bulk operation preview 階段要 flag 這些並讓 user 排除。

## Enforcement(v2.9.0+ 鐵律)

False-positive scan **不是 optional best practice**,是 archive-mail Step 0 Bootstrap 必建的 task `filter_and_scan_false_positives`。任何 search 結果在進 Phase 2 preview 前都要跑這份 rule 的 `flag_thread()` 算法,並在 task description 裡記下「✓ N / ⚠ M / ⚠⚠ K / ❓ J」分布。沒跑就把這個 task 標 completed = 違規。

實際後果(2026-05-01 incident):filter「陳老師 + 林助理 + subject 含『陳君厚』」搜尋出 19 封,265250 是 sibling activity (subject「應徵資料科學統計合作社…」,寄給 scchen 不是 cchen),false-positive scan 沒跑,事後才發現,又走一輪 rm + index 修復。如果 scan 是 enforced task,Phase 2 preview 會 ⚠⚠ flag 這封並讓 user 排除。

## 為什麼需要

`mcp__plugin_che-apple-mail-mcp_mail__search_emails` 用 SQLite full-text 搜尋,query 可能 match 到:
- Subject 含 query 但實際對象不同(例:filter「陳君厚」match 到 subject「應徵資料科學統計合作社博士後研究員(鄭澈,...)」中的「陳」)
- Recipient 是 list 之一但 thread 主軸不是該 contact
- 歷史 thread 標題已改但 message 還是 match

實際案例(2026-05-01 archive 陳老師):filter 是 cchen + 林助理 + 「陳君厚」subject,結果 265250 (寄給 scchen)被 match 到,因為 subject「應徵資料科學統計合作社博士後研究員(鄭澈,**臺灣大學心理學博士**)」沒有「陳君厚」也沒有 cchen,但 sender 是用戶自己,而 subject 含「陳」字導致 fuzzy match。

## 判斷規則

### 對每個 thread 跑 false-positive check

```python
def flag_thread(thread, filter_emails, filter_keywords):
    """
    filter_emails: list of email addresses in the search filter
    filter_keywords: list of keywords (subject search terms)
    """
    participants = set(thread.participants)
    matches_any_email = bool(participants & set(filter_emails))
    
    sender_match = any(
        any(fe in m.sender for fe in filter_emails)
        for m in thread.messages
    )
    
    subject_match_only = (
        not matches_any_email and
        not sender_match and
        any(kw in thread.subject for kw in filter_keywords)
    )
    
    if matches_any_email and sender_match:
        return "✓"  # confident match
    elif matches_any_email and not sender_match:
        return "⚠"  # email in CC list but not principal sender
    elif subject_match_only:
        return "⚠⚠"  # high-probability false positive
    else:
        return "❓"  # unclear, ask user
```

### Flag levels

| Flag | 含義 | 預設行動 |
|------|------|---------|
| ✓ | sender/recipient 直接匹配 filter | 包含 |
| ⚠ | email 在 thread 但不是 principal sender | preview 時提醒,預設包含 |
| ⚠⚠ | 只 subject keyword match,sender 不符 | preview 時 flag,預設**排除**,問 user 確認 |
| ❓ | metadata 不足以判斷 | preview 時提醒,問 user |

## False-positive 範例 patterns

### Pattern 1: Sibling activity sharing keyword

User 同時做幾件事(例如同時應徵多個職位),subject 含類似關鍵字但對象不同。

實際案例:
- Filter: cchen / coco891017 / 「陳君厚」
- False positive: 寄給 scchen 的「應徵資料科學統計合作社」
- Why: subject 含「應徵」但 recipient 完全不在 filter

**Detection**: sender ∉ filter_emails AND principal recipient ∉ filter_emails

### Pattern 2: CC pollution

某 email 把 filter contact CC 但 thread 主題完全不同。

**Detection**: filter_email 只在 CC list,不在 sender 也不在 To

### Pattern 3: Subject collision

不同的 conversation 用了類似 subject(例如「會議通知」)但 thread participants 完全不同。

**Detection**: thread participants ∩ filter_emails == ∅

## Preview 格式

在 `bulk-operation-preview` skill 的 thread breakdown 加 reason:

```
⚠ [2026-03-15] 應徵資料科學統計合作社博士後研究員(鄭澈,...) (1 msg)
    Participants: che830621, scchen
    Reason: sender (scchen@stat.sinica.edu.tw) 不在 filter
            recipient 也不在 filter
            僅 subject 中的「陳」字 match filter「陳君厚」
            高機率為 sibling 應徵活動,非陳君厚老師相關
    建議:排除
```

## False-positive override

User 看到 flag 後可以:
- **接受預設**(排除 ⚠⚠ 標記的)
- **保留**(說「不,這封也要,理由是...」)
- **修改 filter** narrow 範圍重 search

## 改善 search 的策略

長期看,false positive 多表示 filter 太寬。建議在 `.claude/emails.md` 加:

```yaml
# 只把這些 email 視為 chchen 相關
participants:
  primary:
    - cchen@stat.sinica.edu.tw
    - cchen@webmail.stat.sinica.edu.tw
  assistants:
    - coco891017@webmail.stat.sinica.edu.tw
    - coco891017@stat.sinica.edu.tw
    - yijulee@webmail.stat.sinica.edu.tw
    - yijulee@stat.sinica.edu.tw

# Subject keywords 不可作為唯一 match 條件
subject_keywords_strict: true  # 必須同時符合 sender/recipient 才算 match
```

這樣 search 會嚴格 require 至少一個 participant match,subject keyword 只是 supplementary。
