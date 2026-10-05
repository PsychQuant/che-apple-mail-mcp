## Context

- #472 在 `main` 加了 opt-in 的直接寫入路徑（`DirectDraftPath`，`CHE_MAIL_EXPERIMENTAL_DIRECT_DRAFT=1`）：自組 MIME、單一交易寫入 Envelope Index 與 `.emlx`，再用 AppleScript 切換草稿的已讀狀態，讓 Mail 上傳。`message-composition` spec 的「Composing tools never inject a body via AppleScript」卻規定內文 **exclusively** 來自 Mail 的編輯器，兩者不一致。
- #464 加了 opt-in 計時（`ComposeTiming`，`CHE_MAIL_COMPOSE_TIMING_CSV`），但只接在 GUI mailto 路徑（`MailController.composeViaMailto` 的 `recordComposeTiming`），沒有 spec。CSV 沒有路徑欄；每次呼叫各自計算 `ms_since_start`；欄位以逗號直接串接，沒有引號處理。
- `composeViaMailto` 由 `compose_email` 與 `create_draft` 共用。
- 本 change 是 epic #473 的 Step 0（#475），必須在 v3.3.0 發版前完成，且不得改變任何 compose 行為。

## Goals / Non-Goals

**Goals:**

- spec 與 `main` 的實際行為一致：承認 opt-in 直接寫入是第二種 body 來源，並把它的行為寫成可測的契約。
- `create_draft` 的三條路徑（直接寫入成功、直接寫入後退回 GUI、不符條件走 GUI）全部有逐步計時，且能在 CSV 裡分辨路徑、看出一次 fallback 的總成本。

**Non-Goals:**

- 不放寬直接寫入的適用條件（顯示名、Cc、rich text、附件、其他帳號類型分別是 #476–#480）。
- 不改 `format` enum、顯示名的 AX 填入規則、Accessibility 失敗類別。
- 不替 `reply_email`／`forward_email`／`update_draft` 加計時（使用者決定範圍只限 `create_draft` 的三條路徑）。
- 不遷移既有的舊表頭 CSV 檔；遇到就拒寫並說明。

## Decisions

### 自組 MIME 寫入本機資料庫不算 AppleScript 注入

cite-block 的成因是 Mail 對「經 AppleScript 屬性指派的內文」在 MIME 序列化時包上 `<blockquote type="cite">`（#175、#304）。直接寫入的內文從頭到尾不經 Mail 的序列化：MIME 由我們組好、原樣寫進 `.emlx`，Mail 上傳的就是那份位元組（#463、#472 實測伺服器副本與輸入逐欄一致，7 封皆無 `blockquote`）。唯一跑在草稿上的 AppleScript 是切換已讀狀態，不碰內文。所以注入禁令一字不改，只把 body 來源從一種擴成兩種。

替代方案：把注入禁令整條改寫成「內文不得經 Mail 序列化包裝」這種性質判準。拒絕理由：那是總括判準，會在沒想到的邊界上長出新來源（見 `common-spec-prose-enumeration`）；兩種來源的封閉列舉比較不會被誤讀。

### 直接寫入的 requirement 列封閉清單，數字與現行 code 一一對應

eligibility 的 9 項對應 `DirectDraft.Ineligible` 除 `disabled` 外的 9 個 case；寫入前閘門對應 `DirectDraftPath.attempt` 依序檢查的條件。這樣 Step 1–6 每次放寬時，修改的是一條既有 requirement 的清單，而不是另寫一條。

### 計時以「run」為單位，由 create_draft 持有

在 `ComposeTiming` 加一個 run context：`create_draft` handler 在計時開啟時開一個 run（含 `run_id`），直接寫入路徑把它的 marks 放進 run；GUI 路徑的 `recordComposeTiming` 若發現自己在 run 裡，就把 marks 交給 run 而不是自己寫檔；handler 結束時由 run 一次寫出全部列。不在 run 裡的呼叫（`compose_email`）維持原本「自己寫檔」的行為，只多一個 `path` 欄。

run context 用 Swift `@TaskLocal` 傳遞：`createDraft → composeViaMailto → recordComposeTiming` 是同一個 task 上的呼叫鏈，不必在四層函式簽名上加參數。

替代方案：(a) 把 `runId` 當參數一路傳下去——要改 `createDraft`、`composeViaMailto` 的簽名與所有呼叫點，侵入面大；(b) 兩段各自寫檔、只共用 `run_id`——`ms_since_start` 會在 GUI 段歸零，看不出 fallback 的總成本，違反討論結論。

### 每個 mark 帶自己的 path 與 outcome

每一列都帶自己的 `path` 與 `outcome`，但載體是 segment 而不是 mark：`Mark` 不變，`csvRows` 接受多個 `Segment`（每段有 `path`、`outcome`、`config`、marks），合併後依時間排序、以整個 run 最早的 mark 為起點。直接寫入段的 `window_delay`／`step_delay` 為空。

### outcome 用固定代碼，不放原因全文

直接寫入有 2 個原因字串含逗號（版本閘門的「(Mail 16, macOS 27)」與 schema drift 的明細），而 CSV 是無引號串接。改記固定代碼：`DirectDraftPath.Outcome` 增加一個機器用的 `timingCode`，與給人看的 `reason` 分開。代碼清單封閉，寫在 spec。

### 表頭不符就拒寫

`append` 在檔案非空時讀第一行，與 `csvHeader` 不同就丟出錯誤；呼叫端照既有慣例寫 `compose timing:` 到 stderr，不影響 compose 結果。理由：同一個檔案混用 10 欄與 11 欄，任何以表頭解析的讀者都會錯欄，而且安靜。

### 寫入以鎖串行化，欄位也去掉雙引號（verify R1）

verify R1 的 Codex lens 指出：`append` 的「檢查存在 → 建檔 → 讀表頭 → 寫入」之間沒有鎖，而 MCP server 對每個 request 開一個 Task，兩個 `create_draft` 可以同時寫同一個檔；16 個並發 writer 的測試一跑就重現資料遺失。改為：process 內 `NSLock` ＋ 跨 process `flock` ＋ `O_APPEND`，表頭檢查與寫入都在兩把鎖內。`csvField` 另外把雙引號換成單引號，否則標準 CSV 解析器會把它當欄位分隔。

替代方案：改用完整的 CSV 引號跳脫。拒絕理由：欄位值都是固定代碼、數字或旗標，引號跳脫只為了容納本來就不該出現的字元；維持「無引號、不含逗號與雙引號」的格式，讀者用最簡單的 split 也不會錯。

## Implementation Contract

**可觀察行為：**

1. `CHE_MAIL_COMPOSE_TIMING_CSV` 未設定時：產生的 AppleScript 與現在位元組相同；不建立任何檔案；`create_draft` 的結果與現在相同。
2. 設定時，新檔第一行是 `run_id,source,step,t_ref,ms_since_start,ms_since_prev,outcome,window_delay,step_delay,from_address_set,path`，之後每列 11 欄，沒有欄位含逗號。
3. `create_draft` 一次呼叫只有一個 `run_id`：
   - 直接寫入成功：只有 `direct` 列，最後一列是 `returned`，outcome 為 `created` 或 `created:upload_pending`。
   - 不符條件或閘門失敗：`direct` 列（至少 `enter`、`returned`，outcome 為 `not_attempted:<code>`），接著 `gui-mailto` 列；`ms_since_start` 從 direct `enter` 起算、跨兩段連續。
   - upload 請求失敗並還原：`direct` 列 outcome 為 `fell_back:trigger`，接著 `gui-mailto` 列。
   - 直接寫入旗標未開：只有 `gui-mailto` 列。
4. `compose_email`：只有 `gui-mailto` 列，行為與 #464 相同，多一個 `path` 欄。
5. 既有檔第一行不等於新表頭：檔案內容不變；stderr 有一行 `compose timing:`，指出檔名與表頭不符。
6. 寫檔失敗（目錄不存在、權限不足）：compose 結果不變；stderr 有一行 `compose timing:`。

**spec 與規則：**

- `message-composition`：注入禁令段落一字不改；body 來源改為兩種的封閉列舉；新增「Direct-write draft path」。
- 三份 compose 規則的〈現況〉表各加一列「`create_draft`（opt-in 直接寫入，#472）：自組 MIME 寫入本機資料庫，不經 Mail 編輯器、不經 AppleScript 內文屬性」，六類失敗對照表不變。

**驗收：**

- `ComposeTimingTests` 覆蓋表頭、11 欄、多段合併排序與起點、表頭不符拒寫、未設定時 script 不變。
- `DirectDraftPathTests` 覆蓋 outcome 代碼的封閉清單（純函式映射），以及不需要 Mail 的早期結果（旗標關、不符條件、版本閘門失敗後退回 GUI）的步驟序列。寫入之後的結果（`created`、`created:upload_pending`、`fell_back:trigger`）沒有可注入的 controller／writer seam，目前只靠 live 驗證（verify R2，已開 follow-up）。
- `NoBodyInjectionGuardTests` 維持綠燈（它已遞迴掃描整個 `Sources/`，含 `DirectDraft/`）。
- 全套測試綠燈；live：開啟兩個環境變數各跑一次三條路徑，CSV 內容符合第 3 點。

**範圍外：** 任何 compose 行為變更、其他工具的計時、舊 CSV 遷移。

## Risks / Trade-offs

- [`@TaskLocal` 在 `runGuiScript` 換執行緒後讀不到] → `recordComposeTiming` 在 `composeViaMailto` 本體同步呼叫，仍在同一 task；加一個測試確認 run 內的 GUI marks 確實進到 run。
- [直接寫入路徑加計時點後，未開計時時多出成本] → 計時關閉時 mark 呼叫只做一次 nil 檢查，不取時間、不配置。
- [使用者沿用 #464 時期的 CSV 檔，升級後計時「消失」] → stderr 明確說表頭不符與檔名；CHANGELOG 註明要換新檔。
- [outcome 代碼與 `Ineligible` case 名稱漂移] → 代碼由 `Ineligible` 的 case 名稱推導，測試逐一列舉比對 spec 的封閉清單。

- [script mark 的暫存是 process 全域] → 兩個並發的 GUI 呼叫可能拿走對方的 script marks、寫進錯的 run（#464 既有行為）。GUI 呼叫本身會搶同一個 Mail 視窗，實務上少見；已開 follow-up 改以 run 為單位暫存。

## Migration Plan

純新增欄位與 spec 修正，無資料遷移。舊表頭 CSV 由使用者自行換檔（stderr 與 CHANGELOG 提示）。回退：revert 本 change 的 commit 即可，直接寫入本身維持 opt-in。

## Open Questions

（無。範圍、計時路徑、change 歸屬都已由使用者在 #475 的討論中決定。）
