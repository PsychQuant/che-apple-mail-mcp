---
description: "列出歸檔目標、檢查組織階層與 index 歷史，或依已確認計畫執行／恢復分派"
argument-hint: "[list | validate | snapshot <target-id> | plan <target-id> <candidates.json> | execute <plan.json> <manifest.json> | resume <job-id>]"
allowed-tools: Read, Write, Glob, Bash(python3:*)
---

# 歸檔目標登錄與分派

全域登錄檔為 `~/.claude/.mail/archives.json`，與只存別名的 `identity.yaml` 分開。只有使用者明確要求新增／修改登錄時才寫檔；不掃描整台機器、不自動推導父子關係、不自動註冊本次工作區。home 檔案不受 workspace gitignore 管轄，也不代表自動跨機器同步。

## 只讀命令

先定位**目前載入的 plugin 根目錄**（以下 `<plugin-root>`），不要假設使用者 cwd 有 `plugin/`。執行固定 helper，路徑使用獨立 shell 引數／正確引用，不將 registry 內容當程式碼。

```bash
python3 "<plugin-root>/scripts/archive_registry.py" list
python3 "<plugin-root>/scripts/archive_registry.py" validate
python3 "<plugin-root>/scripts/archive_registry.py" snapshot --target "target-id"
python3 "<plugin-root>/scripts/archive_registry.py" plan --target "target-id" --candidates "/absolute/candidates.json"
```

- `list` 顯示全部目標的用途、filter 軸、parent/root、路徑與失效項目。
- `validate` 檢查完整登錄；失效時為非零 exit 與 JSON error，不當成空登錄。
- `snapshot` 讀指定目標**整個組織樹**的 indexes，包含已離開目錄的歷史 ID。`historical_index_only` 是去重證據，不能宣稱知道內容現在在哪裡。任何 scope index 失效即停止；不相關樹的問題仍可由 list 看見。
- `plan` 是只讀預覽，不代表已執行或已取得分派授權。同祖先鏈取最深匹配、跨支線匹配留最低共同祖先 intake、未匹配留 root intake；所有新信都先 capture 到 root，保留子層獨有候選。

候選 JSON 格式：

```json
[{"message_id":"<message@example.invalid>","matched_target_ids":["project-a"]}]
```

`matched_target_ids` 來自**已確認的分類判準**；`filter_axis` 只是說明，不是可執行搜尋語法，也不等同信件歸屬。沒有可靠分類時用空陣列，不猜一個下層。

## 登錄格式

```json
{
  "version": 1,
  "targets": [
    {
      "id": "intake",
      "parent_id": null,
      "workspace": "/absolute/capture-workspace",
      "config_file": "/absolute/capture-workspace/.claude/.mail/config.yaml",
      "output_dir": "/absolute/capture-workspace/communication/intake",
      "index_file": "/absolute/capture-workspace/.claude/.mail/state/archives/intake/email_index.json",
      "purpose": "待分類的信件",
      "filter_axis": "本人的機構帳號"
    },
    {
      "id": "project-a",
      "parent_id": "intake",
      "workspace": "/absolute/project-a",
      "config_file": "/absolute/project-a/.claude/.mail/config.yaml",
      "output_dir": "/absolute/project-a/communication/emails",
      "index_file": "/absolute/project-a/.claude/.mail/state/archives/emails/email_index.json",
      "purpose": "專案 A 往來",
      "filter_axis": "專案協作者",
      "attachment_roots": ["/absolute/shared-research-data"]
    }
  ]
}
```

所有路徑為絕對路徑，父子關係明確宣告。父節點的 output_dir 就是其 intake，不要求目錄恰好叫 intake。`attachment_roots` 可選，用於確實位於 workspace／output 外的附件目錄；不填代表沒有額外目錄。每個目標的 index 所在目錄須不同，確保 threads.json 不互相覆寫；config／output／index 不得共用同一實體路徑（包含大小寫、symlink 與 hard link 別名）。新目標必須先有使用者明確初始化的 config、output 目錄與 `{"version":"1.0","emails":{}}` index；遺失舊 index 不可自動補空檔。

修改登錄時先顯示具體差異，依本次使用者授權寫入，再 validate。只讀命令不會建立上述目錄。

## 執行與復原

新歸檔走 `archive-mail-tree.md`，完成 corpus／目的地預覽及 staging 後，才執行：

```bash
python3 "<plugin-root>/scripts/archive_distribution.py" execute --plan "/absolute/plan.json" --manifest "/absolute/manifest.json"
python3 "<plugin-root>/scripts/archive_distribution.py" resume --job-id "32-character-job-id"
```

plan/manifest 路徑只是資料引數，不插值為程式碼。`execute` 寫入前會重驗快照；同樹未完成工作必須 resume，不得重複 execute。捕捉或目的地失敗保留 journal；修改任何 scope index 或 registry 會停止復原，須先人工核對，不能改 journal hash 來硬闖。

journal 在 root index 同目錄的 `archive-dispatch/<job-id>/state.json`。`phase: complete` 只代表檔案與歷史 index 分派完成，**仍須**對回傳 `reconcile_targets` 執行原有 threads/date/index reconcile。完成後才回報整體成功。

同樹鎖只協調使用此 executor 的工作；執行期間不要並行執行舊版／未登錄的歸檔寫入。它不能阻止外部程式在檢查後改檔。`unclaimed_temps`、`unclaimed_preparation_files` 或 `prior_preparation_cleanup` 若非空，列入報告，由使用者核對；不得自動刪除無法證明所有權的檔案。
