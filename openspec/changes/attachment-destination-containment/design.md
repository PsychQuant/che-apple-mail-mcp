## Context

#402 的 SQLite、空附件與 AppleScript 寫入都使用原始目的地。只加 validator 仍有驗證後換 symlink 與 fallback 繞過兩個缺口。

## Goals / Non-Goals

**Goals:** 將附件目的地授權、建立目錄與發布收斂，保留既有正常操作。

**Non-Goals:** 不重新設計 export 政策、不防範已能控制同一使用者程序／搬移整棵已開啟目錄的攻擊者、不變更下載與帳號解析規則。

## Decisions

### 共用目的地能力

`AttachmentDestination` 驗證原始元件，使用 POSIX realpath 取得實際 canonical path，再透過共用 validator 的純政策入口授權該字串，沿用 export roots。授權不得再次解析候選路徑，以免核准另一個目標卻發布至原路徑。從 `/` 描述元逐層 no-follow 開啟 canonical parent，使用同一描述元發布。既有合法 symlink 解析到已授權 canonical target；驗證後植入 symlink 不追蹤。禁止僅檢查 parent 或將 canonical 驗證結果丟掉。

### 私有暫存與串流發布

SQLite 只取得 Data；AppleScript 每次 attempt 建立新的 0700 UUID 暫存目錄與固定 leaf。來源以 no-follow fd 開啟並驗證 regular file、大小，再用固定上限 buffer 串流到安全 writer 的唯一 sibling temp，最後 atomic rename。避免大附件一次載入記憶體、同名並行儲存共用 temp 及前次殘留被當成成功。

### 失敗分流

目的地授權與發布錯誤採 `AttachmentDestinationError`，立即終止；只有既有附件取得錯誤進入 fallback／下載重試。將內部 stage path 的失敗重映射至呼叫者目的地，成功字串保留 byte count 與 allow_empty 註記。

## Implementation Contract

`save_attachment` 介面參數不變。`save_path` 必須為絕對檔案路徑，原始每一元件符合 `isSafeSegment`。非空 `CHE_MAIL_EXPORT_ALLOWED_ROOTS` 以冒號分隔並取代 home 預設，既有 denylist 一律有效。拒絕時回傳可辨識的 destination 錯誤，不建立未授權目錄、不啟動 Mail／下載。SQLite、allow_empty、MailController 兩個入口與 retry 均受同一發布能力保護。正常覆寫採原子替換；成功後回傳使用者路徑與實際發布位元組數。缺檔、非 regular file 不能用 allow_empty 接受。

驗收包含惡意 path 與替代編碼、denylist leaf、symlink 交換、失敗不 fallback、私有 stage、overwrite／empty／大附件、既有重試測試與完整 Swift 測試。實際 Mail staging 與完整 IDD ensemble 必須另有證據才算 verified。

## Risks / Trade-offs

預設 home 減 denylist 仍允許一般 home 內檔案；需要更窄邊界的部署應明確設定 roots。這是既有 export 的政策，非每封信專屬目錄隔離。新政策拒絕過去任意 `/tmp` 等目的地，使用者需設定 roots。私有 stage 必須在成功及失敗清理，UUID 路徑不重用；超時 Mail 遲到寫入不能觸及正式目的地。父目錄描述元釘住的是已授權目錄物件，不保證能對抗同使用者任意搬移整棵目錄。

## Migration Plan

更新工具描述與設定文件；在測試通過及 review 完成後提交 PR。未獲授權不部署或合併。

## Open Questions

等待可用的 Mail GUI 驗證實際 staging 儲存；Claude weekly quota 恢復後補完整 ensemble。
