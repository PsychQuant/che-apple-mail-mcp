## 驗證紀錄（2026-09-14）

### 實作

四個 MCP 工具已接入 server：讀取／設定政策、只讀分類、明確 plan/id 套用。plugin 命令及授權來源規則已串接；工具清單與 manifest 從 defineTools 對帳為 57 個。

native source 是預覽、refresh 與最後比較的共同來源，只正規化 CRLF／CR 至 LF。完整 bytes 在 move 前比較，原生期限亦於 move 前重查；資料只在記憶體與 osascript stdin，排除於 Codable、plan cache、policy、audit 及 argv。分類 source 仍需 Envelope Index 定位，並需要已存在的 Mail Automation grant。

account／Message-ID 的持久 dispatch 紀錄在能力交付前保留；started／unknown／moved 跨 plan／server 重啟都阻止分類器再次派送，confirmed_preview 不解除封鎖。明確無副作用的 refusal 可重分類；未知結果須獨立核對 Mail，再另行明確確認人工介入。

### 執行證據

- 完整 `swift test`：**1,317 項、11 項略過、零失敗**。
- 針對性 classification／bounded writer／GUI timeout／child accounting 組合：78 項、零失敗。
- 真正的 server configure→classify→apply 分派測試使用 MailController seam，audit.started 先於 mover，audit 不含主旨；政策歷史檔可依 digest 找回。
- 原生 AppleScript 成功編譯。List-ID parser 與 source byte 比較 handler 以合成 RFC 在 osascript 執行（只用 Foundation、不接觸 Mail）；涵蓋 folded headers、重複 List-ID、本文變動、換行正規化與已過期期限。
- 真正的 subprocess runner 以測試命令啟動不讀 stdin 的 child，8 MiB input 受期限控制並回收 child；另驗 pipe 滿載、關閉讀端 EPIPE、取消與逐 byte 寫入。
- 跨 plan／新 engine、持久 started、政策撤回／內容變更、auditing failure、in-flight duplicate apply 均有回歸測試。
- Spectra analyze 無 Critical/Warning，validate 通過。

### 獨立審查

Core/store 審查先修正 namespace ancestor symlink 與 Message-ID 格式。整合 R1 發現 native 完整內容比對與跨 plan 重派缺口；R2 確認兩者修正，另指出大型 stdin 未納入期限。修正 nonblocking writer、啟動前追蹤及共用 deadline 後，獨立 transport delta 複查 PASS。Reviewers 執行的是靜態審查；上述測試由協調者執行。

### 尚待完成

**尚未完整 IDD verified**：Claude OAuth 過期，四個 lens + DA 待重新登入；真實 Mail move／Trash-role live gate 亦未執行。測試替身、編譯及純 Foundation handler 成功，不等於實際 Mail 移動已驗證。

沒有啟用真實分類規則、沒有搬動真實郵件、沒有安裝或發布 binary。Mail 不提供原子 compare-and-move，最後讀取與 move 之間仍有外部改動競態；cooperative local store lock 也不防同一 OS 使用者的惡意程式。不能宣稱完全無敏感資料：audit 包含 identifiers、source account/mailbox，policy/history 含使用者判準，但不含郵件主旨／本文。

## 2026-09-17 原生 Trash 驗收

`ClassificationTrashLiveTests` 使用明確 opt-in 與 UUID 專用帳號信箱，呼叫真正的 `classificationSource`／`moveClassifiedMessage`，沒有 MailController seam。先以不符的預期 source 驗證拒絕與來源不變，再以精確 source 移到帳號唯一的原生 Trash；最後驗證來源信箱為空、Trash 的 Message-ID／sender／subject 與正規化 source digest 保持一致。單一實機測試 **8.36 秒通過**，只使用 466-byte 合成郵件。

政策 store 在獨立暫存目錄使用空政策；沒有批准規則、沒有存取使用者政策，也沒有寄信或永久刪信。這是 native 邊界驗證，不是完整 MCP plan／approval／audit／SQLite 流程的實機證明；後者仍由既有獨立整合測試涵蓋相應部分，不能混稱端到端實測。

第一版 harness 在政策目錄準備階段因 `/var` alias 與 no-follow 檢查不相容而失敗，尚未到 mover；重新讀取確認來源未變。改用既有 store 測試的 POSIX `realpath` 作法後通過。獨立 Codex 指出 XCTest assertion 不會停止後續操作，已將拒絕／來源不變／moved 三個必要條件改成終止式 guard，未知結果不再繼續派送。

普通 `swift test` 為 **1,322 tests／12 skipped／0 failures**（MailSQLite 316／1 skip，server 1,006／11 skip）；新增 live test 在沒有 opt-in 時略過。分類相關選定群組為 **50 tests／1 skipped／0 failures**。

合成信保留於原生 Trash，可循正常流程回復。帳號內的空 UUID 信箱與本輪新建的本機 Import parent／空子信箱已核對為空；Mail 將刪除信箱標為不可還原，已取消對話框並等待使用者確認，不能宣稱清理完成。重現契約與清理邊界見 `docs/testing/classification-trash.md`。

完整 IDD 審查仍待補齊。Claude OAuth 正常，現為週額度限制（工具顯示 2026-09-21 16:00 Asia/Taipei 重設），不是登入過期。原生邊界通過不等於整張 issue verified。
