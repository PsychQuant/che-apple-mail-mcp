# #497：上傳確認的輪詢間隔（250 ms → 100 ms）

直接寫入在送出上傳請求之後，會每隔一段時間讀一次 Envelope Index，看草稿是否已上傳。這張把間隔從 250 ms 改成 100 ms（`DirectDraftPath.uploadPollNanoseconds`）。

## 為什麼能改

- **效益靠推導，不靠這次量測。** 上傳在兩次查詢之間完成時，要等到下一次查詢才發現。延遲大約均勻分布在 0 到一個間隔之間，平均約半個間隔：
  - 250 ms 時，平均晚約 125 ms 發現；
  - 100 ms 時，平均晚約 50 ms；
  - 所以平均早約 75 ms 回報。
- **交易安全規則的 8 項都不受影響。** 迴圈在觸發成功之後，只讀資料庫；10 秒上限、上限從送出上傳請求之前起算、補設已讀，三者都不變。逐項對照見 #497 的 Diagnosis。
- **成本**：10 秒內最多約 100 次唯讀查詢（原本約 40 次），用的是 `DraftStoreWriter` 已開的連線。WAL 下讀不擋 Mail 的寫入。

這一行在 #490 的凍結段裡。改動時已同步更新 `DirectWriteSafetyGuardTests` 的凍結副本：先改副本，確認測試轉紅，再改原始碼，確認轉綠。另有一條測試把間隔限定在 50–250 ms。

## live 驗證（2026-10-06，Gmail 型 IMAP 測試帳號，n = 10）

用這個 branch 建置的簽章 binary，opt-in 直接寫入，計時開啟。

| 項目 | 結果 |
|---|---|
| 走直接寫入並確認上傳 | 10/10 |
| 工具回報錯誤 | 0 |
| 附註「上傳但本機仍未讀」或「讀不到已讀狀態」 | 0 |
| 本機草稿匣副本恰好一份、已讀 | 10/10 |
| 「全部郵件」副本恰好一份、已讀 | 10/10 |
| `trigger_sent → uploaded`（計時 CSV） | 中位數 1,154 ms（360–2,620） |
| 工具回報的「觸發後多久確認上傳」 | 中位數 3.0 秒（2.1–5.2） |

**怎麼讀：**
- 這組數據證明的是行為正確：每封都只有一份、都確認上傳、都已讀。它**證明不了快了多少**。
- 上傳本身的變異（這次 360–2,620 ms）遠大於預期的約 75 ms 差距，n = 10 量不出來。#489 在 250 ms 下量到 `trigger_sent → uploaded` 中位數 1,401 ms（1,017–3,065）；方向一致，但兩次的機器負載不同（本次跑完時 load 約 160），不能直接相減。
- 工具回報的時間從送出上傳請求**之前**起算，包含觸發本身；計時開啟時觸發 script 還多了計時 prelude（見 #496），所以比 CSV 的 `trigger_sent → uploaded` 長。

## 清除

- 10 封探針依 ROWID 從草稿匣刪除（`delete (first message of drafts mailbox whose id is N)`），沒有使用 `whose content contains`（#221）。
- 刪除後草稿匣回到原本的 4 封；約一分鐘後「全部郵件」裡的探針也消失。
- 垃圾桶留有 10 封合成副本：AppleScript 無法永久刪除垃圾桶郵件，Gmail 會在 30 天後自動清除。

## 檔案

| 檔案 | 內容 |
|---|---|
| `live497.py` | 驅動腳本。測試帳號位址從 `EXP497_FROM_FILE` 讀取，不印出、不存檔；不存工具回傳的原文 |
| `results.json` | 每封的結果、`trigger_sent → uploaded` 的毫秒數、探針的 ROWID |

## 重跑

```bash
swift build -c release
cp "$(swift build -c release --show-bin-path)/CheAppleMailMCP" /tmp/CheAppleMailMCP.497
codesign --force --options runtime --identifier CheAppleMailMCP \
  --entitlements Sources/CheAppleMailMCP/Entitlements.plist --sign "$DEVELOPER_ID" /tmp/CheAppleMailMCP.497
EXP497_BIN=/tmp/CheAppleMailMCP.497 EXP497_FROM_FILE=<存有測試帳號位址的檔案> \
EXP497_DRAFTS_MB=<草稿匣 ROWID> EXP497_ALLMAIL_MB=<全部郵件 ROWID> \
python3 scripts/experiments/497-upload-poll/live497.py 10 /tmp/timing.csv /tmp/results.json
```

清除步驟同上，依 `results.json` 裡的 ROWID 逐封刪除。
