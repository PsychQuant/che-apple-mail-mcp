## Context

以 PR #436 的 0cc7d490e5aeed0c4f369acfbc589aed4cf1aff7 為依賴，另開 codex/573-attachment-quarantine；不修改 #436 分支。共用 withAtomicAttachmentFile 目前在寫完內容後直接 renameat。原有模式不保證斷電耐久性，本變更維持原子可見性，不新增 fsync 承諾。

## Goals / Non-Goals

**Goals:** Tier 1／Tier 2 在同一發布點獲得新的隔離標記；標記失敗不發布；驗證既有 containment。

**Non-Goals:** 不修改 roots／denylist、來源取得及下載重試；不複製來源 xattrs／ACL／resource fork；不改 Markdown export；不寫 QuarantineEvents 資料庫、不偽造 Mail 代理名稱或下載 URL；不合併、部署、關閉 issue。

## Decisions

### 描述元隔離標記

使用 Darwin fsetxattr，作用於 O_EXCL／O_NOFOLLOW 建立的 0600 sibling temp 描述元，內容寫完、renameat 之前設定。固定格式 0081;<Unix 秒數十六進位>;CheAppleMailMCP;，不繼承舊檔或 stage 的使用者核准狀態，不虛構事件 UUID。0081 是相容性格式選擇，Apple 公開 API 不承諾其位元格式；須以 macOS xattr 與 Foundation quarantine properties 檢查，Gatekeeper 開啟行為另列 live 關卡。

以 fd 為邊界可避免 URL resource setter／path setxattr 重新解析路徑。不採全程序 LSFileQuarantineEnabled，以免連一般 export 也被改變。

### 失敗不發布

fsetxattr 失敗拋出可辨識的 quarantineFailed（保留 errno）。共用 helper 在 rename 之前拋出，既有 defer 清理 sibling temp；AttachmentDestination 將錯誤包為終止型 io，禁止 fallback／下載 retry。ENOTSUP 亦失敗，不提供停用選項。測試 seam 僅位於 internal atomic helper，writeAttachment／copyAttachment 一律採正式預設 setter。

### 獨立驗證與分支

測試先提交，macOS CI 執行 Tier 1／Tier 2 真正的檔案系統讀寫與 xattr -l，先確認回歸失敗，再加入修正。fixture stage 不代表 Mail 原生實測。既有 opt-in Mail 測試增加 stage／published 屬性輸出及斷言；無可用互動式 Mail 時維持未完成關卡。PR 以 #436 的 head branch 為 base，保持 draft；等 #436 合併後再調整 base。

## Implementation Contract

- withAtomicAttachmentFile 的所有成功出口皆在 rename 前成功設定 quarantine；一般 writeFileAtomicNoFollow 不變。
- AttachmentQuarantineTests 驗證資料、覆寫、空檔、兩種 stage、屬性格式、Foundation 可讀性、原子發布前設定順序、錯誤清理及 symlink 外部哨兵屬性不變。
- 測試以真實 fgetxattr／xattr -l 為屬性 oracle；故障注入僅測共用發布的 fail-closed 行為，不能宣稱真實不支援 xattr 的磁碟已測。
- CI 使用 macOS runner、最小 contents: read 權限、固定 checkout action commit、不讀真實信箱、不部署。
- 新增錯誤不進入 Mail fallback；沿用 AttachmentDestinationError.io 分流。
- macOS Swift 全測與原生 Mail 比較結果分開記錄，不以既有 #436 測試數字代替本次測試。

## Risks / Trade-offs

- 不支援 xattrs 的磁碟現在拒絕儲存 → 明確錯誤，舊檔保留。
- quarantine raw 格式非公開穩定介面 → 記錄格式假設、Foundation 解讀測試與 macOS live 關卡。
- xattr 存在不等於所有啟動途徑均經 Gatekeeper → 不宣稱腳本直譯執行或所有程式啟動都會攔截。
- 同使用者可控制整棵目錄／程序不在 #436 防護範圍；本變更不擴張此承諾。
