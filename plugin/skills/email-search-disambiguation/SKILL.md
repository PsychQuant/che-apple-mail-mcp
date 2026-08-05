---
name: email-search-disambiguation
description: Disambiguate vague email search filters before executing search. Triggers when user uses ambiguous contact references (Chinese name, nickname, role like "老闆"/"老師"), vague time references ("最近"/"上週"), or scope words ("全部"/"所有"). Present 2-3 concrete interpretations and let user choose. Adapted from nsql disambiguation triggers (D1-D5) for email domain.
---

# Email Search Disambiguation

借鑑 nsql 的 disambiguation triggers,adapt 到 email search 領域。

## Triggers

### E1 — Vague Contact Reference

**Examples**:
- 中文人名:「陳老師」、「王教授」、「林助理」
- 角色稱呼:「老闆」、「主管」、「指導教授」、「客戶」
- 公司/組織:「中研院的人」、「stat.sinica 的信」

**Resolution pattern**:

```
「{contact}」可能對應到:
1. {email_1} ({description_1},推薦)
2. {email_2} ({description_2})
3. 其他({user 補充})

你要哪一個?
```

**範例**:
```
「陳老師」可能對應到:
1. cchen@stat.sinica.edu.tw (陳君厚老師,中研院統計所,推薦)
2. scchen@stat.sinica.edu.tw (統計所其他「陳」)
3. 其他

你要哪一個?
```

**怎麼找候選**:
- 從 `.claude/emails.md` 的 `participant_aliases` 讀別名對應
- 從 contacts 或之前 archive 的 thread participants 找匹配
- 如果完全找不到,問 user「我找不到匹配的 contact,你能給我 email 地址嗎?」

### E2 — Vague Time Reference

**Examples**: 「最近」、「上週」、「這個月」、「之前」、「半年內」

**Resolution pattern**:

```
「{term}」可以有不同解釋:
1. 過去 7 天 (今天 - 7d)
2. 上一個完整週/月
3. 自從某事件 (例如:上次 archive 之後)

你指的是哪一個?
```

### E3 — Vague Scope

**Examples**: 「全部」、「所有」、「都」、「整個 thread」

**Resolution pattern**:

```
「全部」可能指:
1. 符合 filter 的 emails (用 search criteria 限縮)
2. 整個 mailbox 的 emails (沒有 filter)
3. 過去 N 天/月的 emails (時間限縮)

範圍多大?
```

### E4 — Ambiguous Operation Direction

**Examples**:
- 「寄給陳老師的信」← 我寄出?還是收到?
- 「跟陳老師往來的信」← 雙向

**Resolution pattern**:

```
「{phrase}」可能指:
1. 我寄出去給 {contact} 的(Sent direction)
2. {contact} 寄給我的(Received direction)
3. 雙向(整個 thread)

你要哪一個?
```

### E5 — Mailbox Ambiguity

**Examples**: 「INBOX 的信」當有多個 accounts、「Drafts」當不確定哪個 account

**Resolution pattern**:

```
你有 {N} 個 mail accounts:
1. {account_1}
2. {account_2}
3. ...

「{mailbox}」要在哪一個 account 找?還是全部?
```

## Disambiguation skip 條件

不需要 disambiguate(直接 execute):

- 明確 email 地址(`cchen@stat.sinica.edu.tw`)
- 精確日期區間(`2026-04-01 to 2026-04-30`)
- Message-ID 直接指定
- 之前 session 已經 disambiguate 過同一個 term(且 user 沒改)

## 與 confirmation-protocol 的關係

E1-E5 是 confirmation-protocol 的 **Phase 1**(Disambiguation)。
完成 disambiguation 後進入 Phase 2(Search Preview),由 `bulk-operation-preview` skill 接手。

## 範例 dialogue

```
user: 把 jonathan 寄給我的信都歸檔

AI [E1 trigger]:
「jonathan」可能對應到:
1. jonathan_tong@ntu.edu.tw (Jonathan Tong,合作研究者)
2. jonathan@some-other-domain.com (其他)

你要哪一個?

user: 1

AI [E4 trigger - direction is "寄給我的" so direction is implicitly received, but let me double check via E3]:
「jonathan_tong@ntu.edu.tw 寄給我的信」我理解是:
- Direction: received only (不含我寄出去的)
- Mailbox: 預設 INBOX(若要包含其他 mailbox 例如 archived 請說)
- Time range: 全部歷史

確認嗎?

user: 對,但是要包含 archived 的

AI: [proceed to Phase 2 with refined filter]
```
