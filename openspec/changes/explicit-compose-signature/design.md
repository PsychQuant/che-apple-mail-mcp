## Context

mailto 使用 Mail 原生編輯器，signature 插入由 Mail 管理。原 legacy body-assignment 已移除，不能引用它說明現在行為。message signature 原生屬性雖存在，但 outgoing message 與 AX window 的可靠綁定尚未完成，故本案不猜同主旨 message 物件。

## Goals / Non-Goals

**Goals:** 呼叫端可以讓 Mail 處理原生簽名，明確選 none/named，並知道視窗的選取結果。

**Non-Goals:** 不解析／重寫 signature 內容、不 heuristic 去除 body 尾端文字、不設定全域簽名偏好、不改 reply/forward、不聲稱已完成 live UI 驗證。

## Decisions

### 參數與預設
signature 是物件，避免真的名叫 none/default 的簽名與保留字衝突。mail_default 為省略時預設，維持 Mail 的選擇；none 停用 native signature；named 要求精確非空 name。其餘 key／型別／不搭配的 name 拒絕。

### 選取與視窗範圍
named 先確認 Mail 的全域同名 signature 恰好一個。GUI phase 位於 From 選取之後、附件之前，沿用既有 native window id／subject／sheet guard，popup 只按 AXIdentifier popup_signature 找。explicit 模式找不到或多個 popup 即拒絕。

None 為菜單第一項，但仍須驗證 AXMenuItem、enabled、None／無標籤；不憑位置盲點，未知 locale/shape 拒絕。named 須在排除第一個 None 的菜單項中只有一個精確名稱；先 None 再 named，避免重選同名不觸發 Mail 套用。footer 或重複名稱不靠猜測選擇。

### 收據
signature phase 先產生 JSON→Base64 收據，包含 mode、selection、selection_verified、selection_applied，再進入附件與 dispatch。成功回傳串接固定 footer，放在既有 Bcc tag 之前；Swift 先剝 Bcc，再剝 signature footer，不讓任意名稱偽造標記。

mail_default 是 best-effort readback，missing popup 不阻擋既有流程。explicit 模式必須選取並回讀一致。選取收據不等於本文已有簽名的證據，不輸出 signature_inserted=true。body 保持原樣；呼叫端使用 Mail 簽名時只傳正文，手動簽名時選 none。

## Implementation Contract

compose_email/create_draft/update_draft 共用同一 schema/parser，controller defaults 向後相容，update 將選項傳給新草稿。明確 signature 失敗必須在 send/save 前拋出，沿用既有窗口清理與 POSTDISPATCH 紀律。收據解析失敗若已 dispatch，必須標示可能已送／已存，不回退重建。

驗證包括 parser、signature phase 順序、popup role、None/name 衝突、編碼收據、Bcc 共存、真 controller seam、AppleScript compile、整套回歸。Mail windows 的 AX readiness=0，故不建立新真實草稿；live gate 與 Claude OAuth 缺口保留。

## Risks / Trade-offs

GUI raise 與 click 間仍有平台 TOCTOU，沿用現有界線，不宣稱原子鎖。Mail default 是否已插入 body 不能只靠 popup 知道；named/none 的可預期操作與誠實收據解決 caller 猜測，實機插入效果仍需驗證。


審查修正：None 與 named 都重開目標 popup，按 AXMenuItemMarkChar 確認唯一已勾選的正確項目。named 僅限兩個 separator 之間的簽名區，不把 footer 管理命令當簽名。附件之後、dispatch 之前再核對選取。收據 selection_applied 表示已執行選取，不假稱最後值一定不同。

文件明訂首次設定先確認草稿正文，或選 none 並自行提供署名；不宣稱此刻已免除所有人工正文複驗。GUI live gate 未完成，這仍是待驗證的選取功能。


R2 視窗身分修正：title→AX bridge 前先核對 Mail 原 _ourId 與 subject，AXRaise 後核對原生 front id；signature 點擊與最終 dispatch 也再驗。COMPOSEIDENTITY 失敗不自動丟棄任何視窗，避免原視窗被使用者改名／編輯後仍被 cleanup 關掉。跨 API check→click 的 TOCTOU 仍揭露，不宣稱絕對鎖定。


Cleanup 亦不依 error label 猜所有權：所有 pre-dispatch 清理先檢查原 ID＋原標題，關閉後仍存續且標題相符才進入 AX discard；AXRaise 後及 discard 點擊前需 native front ID 相同。原視窗消失即不再依標題點另一視窗，原視窗改名則保留。已觀察先前 #405 fixture 的 outgoing matches=0、指定 window id/title 不存在，僅解除該舊視窗清理待辦，不當成新簽名 live gate 證據。
