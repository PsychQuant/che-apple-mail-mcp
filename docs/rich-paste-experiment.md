# Rich clipboard paste：#306 實驗與決策紀錄

本文件整理 2026-07-29 的既有實驗報告，於 2026-09-14 核對 GitHub 留言。**本輪沒有重跑 Mail、建立草稿或寄信。** 歷史報告可支持候選路徑的選擇，不能當成本輪獨立驗證或目前所有環境的保證。

## 決策

Rich paste 是可行的後續整合候選，不能因 `mailto:` 只載純文字，就推論所有 wrapper-free 路徑都不可能承載 rich text。既有實驗優先支持「HTML 加其他相容 flavor」組合；產品目前仍只接受 `plain`，本 spike 不恢復 `markdown`／`html`，也不恢復 AppleScript body 注入。

此判斷的範圍是該次實驗。即使未來某個版本或 variant 失敗，也只能得出該條件下失敗，不能證明所有 rich paste 永久不可行。[#310](https://github.com/PsychQuant/che-apple-mail-mcp/issues/310)另行修正文案與 FB11734014 的上游問題說明。

## 來源與證據層級

| 來源 | 內容 | 本輪如何使用 |
|---|---|---|
| [2026-07-28 23:44 UTC 研究補充](https://github.com/PsychQuant/che-apple-mail-mcp/issues/306#issuecomment-5110956943) | 要求草稿與收件端分別驗證；提醒 HTML-only 重複顯示與 paste 未落地的風險 | 實驗設計與已報告風險，不能覆蓋後來的結果 |
| [2026-07-29 02:42 UTC 草稿結果](https://github.com/PsychQuant/che-apple-mail-mcp/issues/306#issuecomment-5112182988) | HTML 組合草稿通過；列 pasteboard flavor、MIME 片段與環境陷阱 | 歷史實驗報告；當時的未完成項由後一則結果補充 |
| [2026-07-29 04:08 UTC 最終結果](https://github.com/PsychQuant/che-apple-mail-mcp/issues/306#issuecomment-5112852813) | 四種草稿通過；HTML 組合的 Sent 與實收副本通過；附實收 HTML 片段 | 最後的實驗結論，不是本輪取得的完整原始 MIME |

## 歷史結果矩陣

下表的「通過」均指來源留言的報告，沒有把沒有測的項目推定為通過。

| Variant | 草稿：無額外 wrapper 且保留格式 | Sent | 實收副本 |
|---|---|---|---|
| HTML 組合 | 報告通過 | 報告通過 | 報告通過 |
| `public.rtf` | 報告通過 | 未記錄測試 | 未記錄測試 |
| `com.apple.flat-rtfd` | 報告通過 | 未記錄測試 | 未記錄測試 |
| `NSAttributedString` variant | 報告通過 | 未記錄測試 | 未記錄測試 |

HTML 組合為 `public.html`、`Apple HTML pasteboard type`、`public.utf8-plain-text`、`NSStringPboardType`。**不是 HTML-only**。`NSAttributedString` 是實驗 variant 的名稱，不是一個可直接宣告等價的 pasteboard UTI；原始 harness 缺少，不能據名稱重建其完整 flavor 配置。

草稿判準是 HTML 中沒有 `blockquote type="cite"`、`Apple-Mail-URLShareWrapperClass`、`Apple-Mail-URLShareUserContentTopClass`，且粗體、斜體、連結確實保留為 markup。最終留言報告 HTML 組合的 Sent／實收副本也無上述 wrapper，且保留 `BOLDPROBE`、`ITALPROBE` 與 `https://example.invalid/probe` 連結。這些探針是 ASCII；沒有 CJK 的結論。

既有結果認為 HTML 組合最乾淨；其他三種草稿帶較多 inline CSS。這是當次產物比較，不是普遍的 Mail 或 AppKit 規格。

## 兩階段驗證不能合併

既有實驗第一次將貼上與送出連做，發生貼上未落地且送出未成功。後續改成：

1. 原生開啟新信 → 貼入 rich 內容 → 存草稿。
2. 讀取該草稿的 MIME，確認 marker、rich markup 與 wrapper 判準；未通過就不送。
3. 針對同一封已確認草稿執行送出，分別讀回 Sent 與真正實收副本。

草稿檢查可區分「沒有貼成功」與「送出後被改寫」。Sent 不能代替實收副本；成功傳出按鍵也不能代替寄達證據。原生回覆／轉寄的正常引文與本實驗的新信探針不同，不能把此處的全信無 cite 判準直接套在回覆上。

## 尚缺的可重驗資料

2026-09-14 查找目前 repo、相關 worktree、Developer 路徑與 `/private/tmp`，以及本 repo 和舊 `che-mcps` submodule 的可達 Git 歷史，未找到留言列出的 `Scripts/spike306-rich-paste.swift` 或 `Scripts/spike306-stage2-sent.swift`。來源指出前者未提交，最後亦記錄所有 Mail fixture 已清理。

因此目前缺少：

- 原始 harness 與可核對的版本／雜湊。
- 完整原始草稿、Sent、實收 MIME；目前只有留言表格與 HTML 片段。
- 該次實驗的確切 macOS／Mail 版本、帳號協定與完整執行紀錄。

文件核對或人工重建 HTML 片段都不能補成 live 證據。要完成獨立重驗，需找回上述產物，或在明確確認的測試帳號與可用 GUI 環境重新執行既有兩階段實驗。此處不提供會自動寄出的替代 harness。

## 後續整合必須處理的限制

- HTML-only 的重複顯示風險仍需單獨驗證，不能借用組合測試的 PASS。
- 既有實收副本經中繼重包 MIME，且來源觀察到 `big5` 宣告；ASCII 探針不涵蓋 CJK／編碼損壞。
- 來源指出實收信落入垃圾郵件夾；原 harness 只輪詢收件匣／全部郵件會漏抓。重新取得副本時需涵蓋該位置，以 Message-ID 與探針辨識，不能把逾時直接當成送出失敗。
- 每階段須核對視窗身分與焦點。來源記錄 AX 權限異常可呈現零視窗、AppleScript `close` 可靜默無效；不得把自動化沒有執行誤判為 rich paste 失敗。
- 產品整合仍需處理錯誤分類、貼上落點與內容驗證、剪貼簿還原、視窗／草稿身分、受控清理及回覆原文；單一 happy path 不足以啟用新格式。

[#305](https://github.com/PsychQuant/che-apple-mail-mcp/issues/305)的跨客戶端呈現驗證，以及 [#308](https://github.com/PsychQuant/che-apple-mail-mcp/issues/308)／[#309](https://github.com/PsychQuant/che-apple-mail-mcp/issues/309)的替代架構評估，應使用這個受限的實驗結果，不應外推為所有 HTML 或所有傳送路徑的保證。
