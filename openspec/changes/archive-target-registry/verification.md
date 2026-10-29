## 驗證紀錄（2026-09-14）

### 實作範圍

已完成 registry／snapshot／plan、具 journal 與所有權證據的分派 executor，以及 archive-mail 入口、registry／tree 命令、schema、rebuild --index-dir 整合。未登錄維持原路徑；已登錄保留原本 filter 範圍，不擅自擴張。新信先入 root intake，再向下分派；不確定或跨支線歧義留 intake。

### 可執行驗證

- `python3 plugin/tests/test-archive-distribution.py`：27 項、零失敗。包含七個持久階段的中斷子案例，實際 os._exit 於 preparation／intake 後退出，resume／修正重跑，完整本文與附件／index／tombstone，source 修改拒刪、目的地碰撞、scope sibling 歷史變動、共用附件、外部附件 root、CLI execute/resume。
- `python3 plugin/tests/test-archive-registry.py`：19 項、零失敗。包含 377 index／27 md、hierarchy、alias／inode 衝突、獨立 index parent、match 入口，以及直接執行出貨 rebuild shell recipe 的 --index-dir 綁定。
- `python3 plugin/tests/test-archive-mail-recipes.py`：21 項、零失敗。既有路徑／日期 recipe 回歸。
- 合計 **67 項、零失敗**；實際主機為 case-insensitive filesystem，路徑別名測試有執行。
- 七項 SOP 入口／去重／reconcile 內容檢查通過。Spectra analyze 無 Critical/Warning、validate 通過。

### 獨立審查與修正

Codex 靜態審查先後發現 temp fsync 順序、resume 漏查 sibling、shared asset 發布順序、非 canonical／多行附件 link、tombstone 檔名重用、shared blob 清理、preparation 失敗 blob 清理等缺口。均以失敗案例或移除修正的 mutation 重現，再修正並通過。

最後整體靜態審查對其他執行／SOP 路徑通過，只剩 preparation 清理 P2；完成持久 preparing 狀態、inode 先行記錄與安全 abort 清理後，獨立 delta 審查回報 PASS。reviewer 沒有執行測試，所有執行結果由協調者取得。

### 尚未完成與限制

**尚未完整 IDD verified**：Claude OAuth 過期，四個 lens + DA 待重新登入；不得以 Codex 單方審查替代六方驗證。

本輪只操作暫存 fixture，未建立使用者全域 registry、未修改真實 Mail 或實際歸檔。測試驗證程式退出與 fsync 呼叫順序，不宣稱做過主機斷電測試。scope 鎖只協調合作式 writer，外部／legacy 並行改檔不受它控制；已知 index 變動會拒絕繼續，不提供跨檔案系統的單一原子 transaction。

executor complete 後仍須跑 reconcile_targets 的既有 threads/date/index gate，沒有將它誤稱為完整 agent 歸檔成功。Unknown temp／inode 不符檔案保留並揭露，不猜所有權。使用者對捕捉策略的選擇題尚未回覆，目前依提出的建議實作各層搜尋、共同上層 intake，未宣稱取得額外個別答覆。
