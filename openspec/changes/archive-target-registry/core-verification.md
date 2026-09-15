## 核心檢查點（2026-09-14）

本次只完成 tasks 1.1–1.3：全域 registry、跨層 index snapshot 與 routing plan。`archive_registry.py` 的 CLI 是只讀，不建立／註冊目標、不捕捉、不分派、不清除檔案；`execution_status: planning_only` 不構成執行授權。

- `python3 plugin/tests/test-archive-registry.py`：16 項通過。包含 377 個 index entry／27 個 md → 377 個 ID 阻擋重抓、350 個 historical_index_only；子層獨有候選、歧義 intake、循環、stale/corrupt index、JSON 重複 key 與 CLI 無寫入測試。
- hard link 與 APFS 大小寫別名先重現兩項失敗，再增加 device/inode 檢查後通過；不同 target／不同角色不能共用同一 config/output/index。
- `python3 plugin/tests/test-archive-mail-recipes.py`：既有 21 項通過。
- Codex 獨立靜態審查只對核心回報 PASS，未執行測試，也未認定 issue 完成。`/tmp/idd363-review/codex.out` 記錄剩餘 executor／SOP／完整演練。
- Spectra analyze 無 Critical/Warning，validate 通過。

## 尚待完成（不得用核心 PASS 替代）

同樹操作鎖、plan 快照重驗、持久 journal、可重入 executor、目的地內容／附件／index 驗證、來源 tombstone 與本輪副本清理、每個持久階段 failure injection，及 archive-mail／registry command／schema 的端到端整合。另有完整 IDD 審查，Claude OAuth 尚待登入。

使用者的捕捉策略澄清尚未收到回覆；目前規劃依建議保留各層搜尋、共同上層 intake 捕捉。完整方案仍可審查，開發沒有操作真實 registry 或歸檔。
