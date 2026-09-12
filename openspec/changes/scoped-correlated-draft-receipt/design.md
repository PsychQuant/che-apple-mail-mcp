## Context

Refs #409、#405、#427。現有 createDraft 回傳字串並把 recipient verdict 留在 actor property；updateDraft 再掃一次草稿，以新 ID＋主旨決定是否刪舊稿。這會混淆資料列與建立事件。

目前 Mail AX 視窗不可操作。#405 的未寄送 fixture 只取得未發生重存的快照；不能據此選定 Message-ID 作為穩定鍵。正式接線前需要受控 spike，而不是把假 adapter 的成功當成實機證據。

## Goals / Non-Goals

**Goals:** 正確限定實際帳號；一個 post-create receipt 同時證明建立關聯並讀取 To／Cc／Bcc；失敗不洩漏其他候選地址、不誤刪舊稿；正常同主旨更新可成功。

**Non-Goals:** 不用最大 ID 推定建立順序；不把 subject 當成永久身分；不在無證據時新增 Message-ID selector；不改正文產生方式、寄信流程或自動關閉成功視窗。不承諾整個 Mail GUI 流程為跨程序交易。

## Decisions

### 建立關聯證據先於正式接線

`DraftCreationContext` 是每次呼叫的內部值，包含實際 `accountID`、帳號分組的 pre-create ID 集合、請求的 `expectedSubject`／三個 expected recipient 清單，以及由 compose adapter 取得的 `creationBinding`。MCP 參數不能自行構造可信 binding。

候選 adapter 依序調查：建立動作直接取得的 Mail message handle；或從本次擁有的 compose 物件取得、且已驗證重存語意的識別值。不能先以主旨搜尋任一草稿再將其識別值命名為 binding。`from_address` 只代表請求，不代表實際落地帳號。

這個 **adapter 選擇尚未完成**。如果兩種來源都無法證明關聯，維持 gate，重新設計建立路徑；不能以永久拒絕正常同主旨更新來宣布完成。

### 帳號範圍與建立前快照

快照在建立前取得，ID 以 account UUID 分組。若實際目的帳號尚未知，準備階段可以取得可能目的帳號的 **ID-only** 集合；不得讀取其 recipient 地址。adapter 確定實際帳號後，只採用相應集合。實際帳號沒有有效 baseline 時，receipt 為 unavailable。

Post-create receipt 只列舉該帳號的 drafts containers。先驗證所有候選 metadata，排除 baseline IDs、確認 creationBinding 並檢查 subject 與 expectedSubject 精確相等，唯一匹配後才讀三個 recipient 欄位。任何列舉／metadata／recipient 錯誤都中止，不忽略壞資料繼續挑下一筆。

### 單次回讀與每次呼叫的結果

每次輪詢只執行一個 script，同時回傳 ID、account、subject、To／Cc／Bcc。createDraft 與 updateDraft 共用同一個結果，不再額外跑 ID receipt，也不再讀寫 `lastRecipientReceiptOutcome`。

保留 #414 的政策：只有成功、完整的 not-found 結果可以輪詢，最多三次、間隔 0.4 秒；錯誤、歧義與身分不可證立即停止。這不是整次工具呼叫的延遲上限。

### 嚴格 wire 格式與狀態

採 Foundation 產生／解析的版本化 JSON，取代分隔符字串。正常回應：

```json
{"version":"1","status":"found","account_id":"11111111-1111-4111-8111-111111111111","id":"102","subject":"S","to":["a@example.test"],"cc":[],"bcc":[]}
```

`version` 固定為字串 `"1"`；`candidate_count` 是 canonical ASCII 十進位字串，範圍 2...9223372036854775807，不接受 JSON number、小數、指數或前置零。先保留字串再轉整數，避免 Foundation 在驗證前捨入。`id` 是非空 ASCII 數字字串；`subject` 與地址欄位保留字串內容，不做隱含型別轉換。`not_found` 只有 version/status；`ambiguous` 另有 candidate_count；`unavailable` 另有 reason_code。reason_code 限於 missing_scope、identity_unproven、read_failed、invalid_payload、wrong_scope；不使用任意字串攜帶 raw payload。失敗回應不得附帶候選地址。範例使用虛構 UUID；正式 account_id 必須由 Mail 的實際帳號證據取得。

解碼拒絕未知 version/status、缺欄位、錯型別、未知欄位、錯誤帳號、非數字 ID 與破損 JSON；失敗轉 unavailable，不建立 mismatch。原始破損 payload 不回顯到對話或 log。JSON 格式正確不等於 creation identity 正確：binding 必須由 adapter／選擇器實際驗證，不能靠回傳一個 true 或原樣 echo token 冒充。

### 刪除門檻與相容性

只有身分已確認、且 To／Cc／Bcc 均匹配的 receipt 可允許 update 刪除原稿。其餘狀態保留原稿。這改變原先「recipient unavailable 仍可刪」的策略，必須在 tool descriptions 揭露。

原稿定位也保留實際 account UUID，刪除仍限定原帳號＋原 row ID＋主旨，不在 ID 漂移後猜另一筆。找不到原 row 不等於邏輯草稿已消失，不再據此宣稱只剩 replacement。

保留現有 MCP 結果形式，`recipients_verified` 現在涵蓋三欄；可信 mismatch 的 diff 加入 `to`。not-found／ambiguous／unavailable 不產生虛構 found-address 差異。可回傳 `draft_receipt` 的帳號／ID／主旨快照，但不得承諾其 ID 跨後續重存穩定。

## Implementation Contract

- `DraftCreationContext`／`DraftReceiptRecord`／`DraftReceiptOutcome` 為 call-local 值；不依賴前次呼叫狀態。
- `readDraftReceipt(context:)` 只執行帳號範圍內的單一合併 script；無可信 context 時在查詢前拒絕，不退回全帳號查地址。
- `decodeDraftReceipt(payload:context:)` 嚴格驗證 wire shape／scope；`compareRecipients(expected:record:)` 對期望值移除 display name，沿用大小寫／順序不敏感的集合比對。
- `updateDraft` 只消費 create 操作帶回的同一份 receipt，不重新挑選同主旨候選，不以不同查詢拼接 ID 與地址。
- 以 fixture 覆蓋跨帳號同主旨、舊稿換 ROWID、phantom create、同帳號多候選、To-only 差異、部分讀取失敗、破損 payload；spy 證明不讀其他候選地址與不執行 delete。
- Live gate 要實際完成正常同主旨 update、明確寄件人／預設帳號、重存與帳號歧義案例，並收尾唯一標記的未寄送 fixture。只讀取到未變快照不算完成。

## Risks / Trade-offs

最大的風險是 Mail 沒有可取得且足以證明建立關聯的 adapter。此風險不能用規格文字消除；接線依賴 live spike 的具體 API／輸出／反例紀錄。缺 scope 或可信 receipt 時多保留草稿，是失敗處理而非最終正常路徑。

ID-only baseline 仍可能需要跨帳號準備讀取；效能驗收要分開計算 baseline、定位與 receipt，不把「單次合併 receipt」冒稱所有流程只有一個 Mail 呼叫。已知的 GUI／授權 gate 與 #405 fixture 收尾仍需可操作桌面。
