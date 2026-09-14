## 核心／store 檢查點（2026-09-14）

已完成 tasks 1.1–1.2：自訂 policy、規則指紋批准、衝突／保護狀態分類，以及本機私有原子儲存。Audit append 型別與持久寫入已具備，但「audit 成功後才 dispatch」仍須 plan/apply 引擎整合，不能把儲存測試當作已完成該契約。

- `swift test --filter EmailClassification`：25 項通過（14 classifier + 11 store）。
- 完整 `swift test`：1,290 項、11 項略過、零失敗。
- Codex 核心靜態審查的兩項 finding：祖先 symlink、Message-ID 格式過鬆；先以回歸測試重現 9 個失敗斷言，再修正。
- 獨立 R2 對這個 bounded core/store 複查 PASS；之後協調者另外修正 Swift collection 型別推導及 macOS 暫存路徑表示問題，最終上述 focused／full tests 通過。沒有把 reviewer 的靜態閱讀說成它執行了測試。
- 沒有讀寫真實分類 policy、沒有操作真實 Mail；所有 store 測試都注入暫存目錄。原有使用者 binary／checksum 變更未動。

## 尚未完成

短效 plan／明確 ids claim／stale policy/message 重驗、寫前 audit 與 at-most-once 派送、guarded native Trash move、MCP schemas/dispatch、plugin 命令與授權來源，以及完整 IDD／原生 live gate。這個檢查點不能當成 #356 已交付；目前尚未新增可叫用的分類 MCP tool。

接續仍在 `codex/356-email-classification`，以 #340 runtime stack 為底。不得重新詢問已回答的 auto-trash 政策，也不得用此開發授權替使用者批准具體清理規則。
