---
description: "依全域 registry 將信件先捕捉到上層 intake，再按已確認目的地分派"
argument-hint: "<target-id> [本次 filter 限制]"
allowed-tools: Read, Write, Glob, Bash(python3:*), mcp__plugin_che-apple-mail-mcp_mail__search_emails, mcp__plugin_che-apple-mail-mcp_mail__get_email, mcp__plugin_che-apple-mail-mcp_mail__get_email_headers, mcp__plugin_che-apple-mail-mcp_mail__list_accounts, mcp__plugin_che-apple-mail-mcp_mail__get_special_mailboxes, mcp__plugin_che-apple-mail-mcp_mail__list_attachments, mcp__plugin_che-apple-mail-mcp_mail__list_attachments_batch, mcp__plugin_che-apple-mail-mcp_mail__save_attachment, mcp__plugin_che-apple-mail-mcp_mail__batch_export_emails_markdown
---

# 階層歸檔

本命令處理已登錄目標，使用 `archive_registry.py` 與 `archive_distribution.py`，不是把目錄名字當成分類規則。未登錄者回原 `archive-mail`；不自動建立 registry。

## 階段清單

建立並逐項更新工作清單：驗證 registry／scope；搜尋與去重；目的地預覽；完整 staging；執行或 resume；所有受影響目標 reconcile；報告。任一步未完成不得回報整體成功。

## 1. 範圍、搜尋與歷史

1. 用 registry helper 的 snapshot 讀取所選目標的整個組織樹。缺少／損壞 index 即停止，不以空歷史繼續。保留 JSON 快照、index 指紋及 locations 至本輪結束。
2. 本命令未另限 filter 時，各目標依自己 config 的 filters 搜尋，因為父層 filter 不保證包含子層。從原 `/archive-mail <filter> <output>` 轉入時，**保留原本已授權的 filter／範圍**，不默默搜尋其餘所有 config。需要擴大 corpus 時先顯示範圍並取得使用者同意。
3. 搜尋、sender/recipient 判斷、refinement、false-positive scan、草稿處理及 Message-ID 正規化沿用 `archive-mail.md` Steps 1.4、1.5、3–4 的程序；以每個目標自己的 config 和共同 identity alias 結果執行。這是引用程序，**不要遞迴呼叫 /archive-mail**。
4. 各層候選以真實 Message-ID 去重，再排除 snapshot.history 的全部鍵（包含 tombstone），即使 local 設 `last_archived` 也必須做 registry 去重。date-only 策略仍可作額外篩選，不能取代已知 ID 歷史。
5. 樹內目標由 registry index 負責；`distributed_archives` 若解析到樹內 output，略過重複掃描。樹外目錄沿用原 Step 2.1 的只讀額外 dedup，缺目錄仍警告。不從 distributed_archives 反向建立 parent。
6. 已在 history 的信只回報位置及 index-only 狀態，不重抓補檔。這不阻擋保留「父 filter 沒抓到、child 才發現」且 history 沒有的新信。

## 2. 目的地預覽

為每個新 Message-ID 寫 candidates JSON；matched_target_ids 只放已確認分類判準命中的目標，沒把握放 `[]`。同名 collaborator 或 filter 命中不是自動歸屬證據。以 helper plan 產生 plan.json。

預覽必須逐項列出信件、發現來源、capture root、最後目的地與判斷理由。跨支線歧義留共同祖先 intake，無匹配留 root intake。先依既有 confirmation-protocol 取得這份 corpus／目的地映射的授權；先前只批准單一 workspace 的動作，不能當成額外子樹寫入授權。沒有新信則報告既有位置／去重結果後結束，不呼叫 execute。

## 3. 完整 staging（尚未寫入歸檔目標）

- 在獲准的 workspace 下建立專用、一般名稱的暫存目錄，例如 `archive-stage-<uuid>`，以檔案 API 建立，所有路徑作為資料引數。不能在 `$HOME/.claude` 等 export 禁止位置繞過工具政策。
- 引用原 Steps 5、5.5 的完整本文匯出、附件清單與下載程序，輸出改為 stage。**此時不更新任何目標 index／threads**。凍結六欄 frontmatter 與 verbatim body，不能為方便分派改寫內容。
- 檔名由已支援的 `filename_style: archive-mail` 或原 Date-header 同源 fallback 產生。先檢查預計 intake／目的地皆沒有同名檔，且各目標 index 的歷史 entry（含 tombstone）沒有保留該檔名；以大小寫與 Unicode 等價比較。碰撞時依原命名規則另取 `-N`，更新預覽與 manifest。executor 永不覆寫既有檔。
- 每封所有 explicit／inline 附件均下載到 stage 內，使用原 safe leaf 與 Markdown label／URL encoding 規則。只使用標準 inline links：`[label](URL-encoded-relative-path)` 或 `![label](URL-encoded-relative-path)`；不帶 title、不用 reference-style，不留下同附件的 `./...` 等另一拼法。不要改與附件無關的原始信件內文連結；若無法安全準備，停止該項並揭露。
- manifest 必須列出**全部已列舉附件**。任何附件下載失敗、內容為 partial/header-only、真實 Message-ID 未確認，皆不得提交該封為完整 capture；保留 stage 與錯誤供重試，不用空 attachments 假裝成功。
- 分別讀 root 與目的地 config 的有效 attachment_routing（#334 逐欄覆寫）；將每個附件的 intake_path／destination_path 設為該目標 workspace 相對路徑，或明確登錄 attachment_roots 內的絕對路徑。暫存位置不必與最終位置相同；executor 會依對應清單改寫已知附件 URL。

manifest.json 範例（entry 取自這份 stage Markdown／同源 manifest）：

```json
{
  "stage_root": "/absolute/workspace/archive-stage-run",
  "messages": [{
    "message_id": "<message@example.invalid>",
    "markdown": "2026-09-14_Topic.md",
    "filename": "2026-09-14_Topic.md",
    "entry": {"date":"2026-09-14T10:00:00+08:00","subject":"Topic","thread_key":"Topic"},
    "attachments": [{
      "file":"assets/report.pdf",
      "intake_path":"correspondence/attachments/2026-09-14_Topic/report.pdf",
      "destination_path":"correspondence/attachments/2026-09-14_Topic/report.pdf"
    }]
  }]
}
```

manifest messages 必須恰好對應 plan 的新信。不要把 filesystem 路徑／郵件字串插入可執行程式碼。

## 4. 執行與復原

依 registry command 的 execute 呼叫套用 plan + manifest。執行器會自行建立 intake 副本與 index，複製並驗證目的地本文／附件／index，寫入來源 distributed_to tombstone，再清除可證明為本輪建立且未修改的 intake 副本。未知或歧義項的目標是 intake，本來就不清除。

同樹 busy 即等待既有工作；stale plan 即重新 snapshot／plan／預覽。已有未完成 journal 時只 resume 同一 job，不重跑 capture。若 scope index 被外部修改，保留現有副本與 journal，先核對變動；不可竄改指紋或刪掉 journal 來假裝新工作。不要並行舊版歸檔寫入。

## 5. 最終 reconcile 與報告

遍歷 executor 回傳的 `reconcile_targets`，逐一使用該目標的 config、output_dir 與 index_file，引用原 Step 5.7／6／8.5：重建 threads、核對 Markdown→index、保留來源 tombstone、更新日期 audit／last_updated。registry 明確 index_file 為權威，不從另一個 slug 猜新 index。threads.json 位於該 index 同目錄。呼叫 `/archive-mail-rebuild-threads <registered-output-dir> --index-dir <registered-index-parent>`，不可省略 --index-dir 回到另一個 slug 推導位置。後續 Step 6／8.5 的 INDEX_FILE、THREADS_FILE 均使用這份明確綁定。

只有所有 gate 完成才回報成功。報告包含捕捉數、每個目的地數量、留 intake 的未分類／歧義信、既有歷史跳過數、index-only 數、attachment 錯誤、journal/job id，以及仍待 reconcile 的目標。executor 的 complete 不等於整個 archive workflow 已成功。
