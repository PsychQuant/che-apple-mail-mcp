# Deferred live verification — KNOWN GATE 不可以只寫在 closing comment（#318）

## 規則

任何 shipped feature 若存在「文件明說、但尚未實際執行的 live 驗證關卡」（KNOWN GATE / live FDA spot-check / 單元層驗不到的行為），close 該 issue 前**必須二擇一**：

1. **(a) 真的跑掉**：執行該 live 檢查，把結果（含指令與觀測值）寫進 closing comment。
2. **(b) 留下活的追蹤**：貼 **`blocked-on-setup`** label 保持該 issue（或專屬追蹤 issue）**OPEN**，且**同步在受影響 tool 的 description 加一句 caveat**。

**禁止**：在 closing comment 寫「建議 merge 前 spot-check」然後直接關閉出貨——這正是 #268 的違規模式。

## 為什麼（#318 稽核的兩個決定性發現）

**1. Closing comment 是死信。** #268 出貨時，KNOWN GATE 警語只存在於關閉 issue 的 closing comment；同一時刻 `Server.swift` 的 tool description 卻寫著**無但書的確信保證**（「compare full-path == full-path directly instead of a leaf-suffix heuristic」）。呼叫端（LLM/consumer）讀得到 description、永遠讀不到 closing comment——於是照著過度自信的建議簡化了自己的防禦分支。#315 執行該 gate 時它**失敗了**（7/7 帳號 inert），而文件承諾的 fail-safe（省略 `_path`）也從未觸發：錯誤值與正確值在 wire 上不可分辨。

**2. 機制早就存在，缺的是強制。** `blocked-on-setup` label 的描述（"execution blocked on environment / account / external setup, not on code work"）與此模式語義完全吻合，但 #179/#249/#268 一個都沒貼。不需要發明新機制——需要的是本規則。

## 家族稽核結論（2026-08-01，#318）

| Issue | Deferral | 結局 |
|---|---|---|
| #179 | live multi-account QA deferred, "No follow-up issue filed" | 後由 #249 接手清償 — **verified-later** |
| #249 | 接手 #179 的追蹤 issue | 7 帳號實測、PR #260 落地 — **verified-and-completed**（正面範例：deferral 被獨立 issue 接住）|
| #268 | KNOWN GATE：Gmail byte-identity spot-check，「同 #179/#249 deferral」 | 由 #315 執行且**失敗** — **verified-and-failed** |

Sweep（嚴格 marker `KNOWN GATE`/`建議 merge 前`/`單元層驗不到` 全庫搜尋）：唯一命中 #268——**緊密家族，非流行病**。誠實殘留：`deferral` 泛搜滿 30 筆上限、軟候選 #47 未深挖；若日後發現同形狀案例，比照本規則處理。

## 與 CHANGELOG「scope 排除」的分工

CHANGELOG 的 scope-caveat（如 #303 對 `.mcpb` 的「inert, tracked in #312」）是**永久性範疇排除**——功能對某管道天生不適用，生命週期是「直到有人實作」。本規則管的是**暫時性 KNOWN GATE**——應該儘快跑掉的驗證，生命週期是「直到有人執行」。**兩者互不替代、不可混用**：把 KNOWN GATE 寫進 CHANGELOG 不算完成義務（沒人會回頭讀舊 entry），必須走上面的 (a) 或 (b)。

## Retro 義務（進行中）

- #268/#315：caveat 語句隨 #315 的修復 PR 補回 `get_special_mailboxes` description（若修好後仍有殘餘限制）。
- #179/#249：無需行動——已是正面範例。
