---
name: bulk-operation-preview
description: Show structured preview of bulk email operations (5+ emails) before execute. Group by thread, flag false-positive candidates, count side-effect scope (files written, attachments downloaded, mailboxes touched). Use after email-search-disambiguation finishes Phase 1, as Phase 2 of the confirmation protocol.
---

# Bulk Operation Preview

當 search 結果 ≥ 5 emails 或操作會 touch 多個 emails 時,先 show 結構化 preview 讓 user 過目。

## Preview Format

### 基本結構

```
搜尋結果:{N} 封 emails (by {filter_summary})

Threads 分布(按時間排序):
  ✓ [{date}] {thread_key} ({M} msgs)
  ✓ [{date}] {thread_key} ({M} msgs)
  ⚠ [{date}] {thread_key} ({M} msgs)  ← potential false positive,reason: {reason}
  ...

附件:{K} 個檔案 ({total_size} 預估)
  - {file_1.pdf} ({size_1})
  - ...

⚠ {flag_count} 個 threads 標示為 potential false positive
要排除嗎?確認操作範圍?
```

### Pipeline-style filter summary

借 nsql pipeline format:

```
Mail
  -> filter(sender = 'cchen@stat.sinica.edu.tw' 
            OR sender = 'coco891017@webmail.stat.sinica.edu.tw'
            OR subject contains '陳君厚')
  -> group(thread_key)
  -> sort(first_message asc)
```

讓 user 一眼看出 search 邏輯。

## False-positive flagging(整合 false-positive-detection.md)

每 thread 跑 false-positive detection:

| Flag | 條件 |
|------|------|
| ✓ | sender/recipient 直接匹配 filter 中的 email 地址 |
| ⚠ | sender 不在 filter 但 subject 含 filter 關鍵字(可能 false positive) |
| ⚠⚠ | sender 完全不在 filter 且 subject 也只含通用詞(高機率 false positive) |
| ❓ | metadata 不足以判斷(少於 1 封 email 在 thread) |

詳見 `rules/false-positive-detection.md`。

## Side-effect scope counting

在 Phase 3 (Operation Confirmation) 之前,count operation 影響的 scope:

```
我將執行:
  - 寫入 {N} 個 markdown 檔到 {output_dir}/
  - 下載 {K} 個 attachments ({total_size}) 分流到:
      → {data_dir}/ ({data_count} 個資料檔)
      → {documents_dir}/ ({doc_count} 個文件附件)
  - 建立/更新 {index_count} 個 index files
  - {modify_mailapp ? "修改 Mail.app 標記/移動" : "不修改 Mail.app 內容(read-only)"}

預估磁碟用量:{disk_estimate}
預估執行時間:{time_estimate}

⚠ 此操作{reversible ? "可以 undo(刪除生成的檔案)" : "無法 undo"}
確認執行嗎?
```

## Thread breakdown 細節

按 first message date 排序,format:

```
[YYYY-MM-DD] {thread_key} ({msg_count} msgs)
   Participants: {top 3 participants}
   First: {first_sender}, Last: {last_sender}
```

對 chchen 案例:

```
[2026-04-29] 新聘博士後研究學者繳交資料 (2 msgs)
   Participants: yijulee, che830621, cchen, coco891017
   First: yijulee, Last: che830621

[2026-04-19] 後續面試報告時間請教 (5 msgs)
   Participants: che830621, cchen, coco891017, yijulee, tsoping
   First: che830621, Last: che830621

⚠ [2026-03-15] 應徵資料科學統計合作社... (1 msg)
   Participants: che830621, scchen
   First/Last: che830621
   ⚠ Reason: sender (scchen) 不在 filter pattern,subject 含「陳」但實際對象是另一個 unit
```

## 與 confirmation-protocol 的關係

`bulk-operation-preview` 是 confirmation-protocol 的 **Phase 2 + Phase 3**。

Workflow:
- Phase 1 (disambiguation, by `email-search-disambiguation` skill) → 確認 filter
- **Phase 2 (search preview, by THIS skill)** → 展示找到的 emails + flag false positives
- **Phase 3 (operation confirmation, by THIS skill)** → 展示 side-effect scope
- Phase 4 (execute) → 進入主 command 的執行階段

## 範例(完整 preview)

```
搜尋結果:19 封 emails

Filter:
  Mail
    -> filter(sender contains 'cchen@stat.sinica.edu.tw'
              OR sender contains 'coco891017'
              OR subject contains '陳君厚')
    -> sort(date desc)

Threads 分布:
  ✓ [2026-04-29] 新聘博士後研究學者繳交資料_鄭澈博士 (2 msgs)
       Participants: yijulee, che830621, cchen, coco891017
  ✓ [2026-04-19] 後續面試報告時間請教 (5 msgs)
       Participants: che830621, cchen, coco891017, yijulee, tsoping
  ✓ [2026-03-31] 面試提醒 (1 msg)
       Participants: che830621, coco891017
  ✓ [2026-03-27] 君厚老師面試時間與地點 (時間異動) (2 msgs)
  ✓ [2026-03-26] 君厚老師面試時間與地點 (2 msgs)
  ✓ [2026-03-18] 應徵博士後研究員(鄭澈) (6 msgs)
  ⚠ [2026-03-15] 應徵資料科學統計合作社... (1 msg)
       Participants: che830621, scchen
       ⚠ sender 不是 cchen,subject 含「陳」但實際寄給統計所其他單位

附件:1 個 (handout.pdf, ~100 KB)

⚠ 1 個 thread 標示為 potential false positive
是否排除 [2026-03-15] 那封?

選項:
  (a) 排除 false positive,歸檔 18 封
  (b) 保留 false positive,歸檔 19 封(用戶確認也要這封)
  (c) 修改 filter(narrow / broaden)
  (d) 取消

你選哪個?
```
