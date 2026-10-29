## Why

#409 的回讀可能認錯同主旨草稿並揭露不相干地址；#405 的重存又會讓舊稿以新 ROWID 冒充 replacement。需要把回讀與刪除建立在同一份可驗證的建立證據上。

## Problem

目前以全帳號同主旨的最大 ID 選草稿，只檢查 Cc／Bcc，updateDraft 另跑一份 ID receipt。局部讀取錯誤與破損 payload 可能被當成有效結果（#427）。

## Root Cause

缺少由實際 compose 操作產生的帳號／建立關聯證據；ID、地址與刪除門檻使用不同查詢，且共享最後一次 verdict。

## What Changes

- 由實際建立操作取得帳號與建立關聯證據，禁止以預期寄件人、主旨或最大 ID 猜測。
- 合併 ID、subject、To／Cc／Bcc 為一次帳號範圍內的 receipt read，排除 pre-create ID，並驗證本次建立關聯。
- 改為每次呼叫攜帶的 typed outcome；移除共享 verdict 與舊寬鬆 parser。
- **BREAKING**：`recipients_verified` 改為完整 To／Cc／Bcc 且身分已確認的保證；缺乏可信 receipt 時 update 不刪除舊稿。

## Proposed Solution

先定義可測試的 receipt protocol、候選選擇與嚴格解碼；實際 Mail adapter 必須通過受控 live spike 才能接線。帳號或身分不明時不掃描其他帳號的地址、不回報 verified、不刪除舊稿。這是失敗處理，不是將正常同主旨更新永久降級為 unavailable 的完成方案。

## Success Criteria

正常同主旨更新取得正確且唯一的新稿；其他帳號同主旨、舊稿重存、部分讀取錯誤及破損 payload 都不能變成假確認。一個 receipt 同時供 ID 與三個地址欄位判定。實機關卡未完成前不得宣稱交付。

## Capabilities

### New Capabilities

- `correlated-draft-receipt`: 帳號／建立關聯 context、嚴格 payload、唯一候選與失敗狀態。

### Modified Capabilities

- `message-composition`: 每份草稿的 To／Cc／Bcc 共用完整 receipt，取代只在 named Cc／Bcc 時讀取的舊契約。
- `draft-update`: 刪除只能使用同一份可信 receipt，移除「新 ID＋同主旨足夠」與 recipient unavailable 仍可刪除的舊保證。

## Impact

影響 DraftRecipientReceipt、MailController、ComposeScriptBuilder 的建立結果、Server descriptions／manifest、相關 tests 與兩份既有 specs。不新增外部套件或傳送郵件。#405 的穩定鍵調查與 #427 parser 驗收共用此證據鏈，保持各 issue 的進度可追蹤。
