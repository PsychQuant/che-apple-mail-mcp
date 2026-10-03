## Why

這個 MCP 對「動作做完之後 Mail 內部發生了什麼」完全是盲的：`create_draft` 只知道 GUI 腳本跑完，不知道草稿有沒有上傳、何時上傳、為什麼沒上傳。#463 的 spike 證明，答案其實就在 Mail 行程的 unified log 裡（例如「建立 append action」之後有沒有出現「引擎收到通知」），但目前只能由人在終端機手動拿兩個時間窗口對照。使用者要的是通用的診斷通道：任何 Mail 事件都能查，用來找出事件鏈在哪一步斷掉；#463、#405、#409、#464 都會用到它。

## What Changes

- 新增一個唯讀 MCP 工具 `get_mail_log_events`（暫名），讀取 Mail 與 email 兩個 subsystem 的 unified log。
- 以 `detail: "brief" | "detailed"` 切換輸出，預設 `brief`：
  - `brief`：時間、`subsystem:category`、`formatString`、只抽出數字參數、`activityIdentifier`；不輸出任何 `%@` 的內容，因此只要模板是編譯期字串，就不會帶出帳號、主旨或收件人（verify round 3 finding 19：原本的「結構上不可能」少了這個前提）。
  - `detailed`：`brief` 加上完整原始 `eventMessage`、行程名稱、threadID；選用的 `redact_identifiers`（預設關閉）可把 email、UUID、Message-ID 換成代號。
- 時間窗口：預設最近 10 分鐘，上限 60 分鐘，預設 200 筆；另有 `around`（給一個時間點，取前後 N 秒）。回應沿用 `{results, returned, limit, truncated}` 外殼，並加上實際涵蓋的時間範圍。
- 讀取 `log show --style ndjson` 的輸出（以子行程 spawn），設有 deadline 與輸出量上限。
- 新增一個極小的白名單比對器，v1 只辨識 IMAP 上傳完成的 `APPENDUID` 回條（它的 `formatString` 整行都是參數，簡短模式否則看不出來）。
- 工具 description 與詳細模式的回應開頭，明確標示輸出含帳號識別資訊，不應貼進公開 issue。

## Non-Goals (optional)

- 不做全面的事件分類表：實測 15 分鐘內單一 category 就有 43 種 `formatString`，對照表綁在私有格式上，維護成本高於價值。
- 不做斷鏈偵測（`explain_sync`）與雙窗口自動比對：本變更只提供事件，「對照後看出差異」仍是呼叫端的推理步驟；是否值得做等這個工具上線、累積使用經驗後再決定。
- 不改變 Envelope Index 與 `.emlx` 的讀取路徑；日誌是觀察通道，不得取代資料庫成為狀態來源（`.claude/rules/r-must-direct-db.md`）。
- 不修改 Mail 的資料庫，也不觸發同步（那是 #463 的主題）。
- 不採用 `OSLogStore`：兩條路徑都已在簽章環境驗證可讀，選 `log show` 的理由與可逆性見 design.md。
- 不支援非 macOS 27.2／Mail 16.0 以外版本的保證：格式是私有的，其餘版本以 `unclassified`／`unknown` 誠實回報，不猜。

## Capabilities

### New Capabilities

- `mail-log-diagnostics`: 唯讀查詢 Mail 行程的 unified log，提供簡短（結構上無識別資訊）與詳細（含原始行）兩種輸出、窗口與筆數上限、誠實的未知語意，以及 `APPENDUID` 回條的辨識。

### Modified Capabilities

(none)

## Impact

- Affected specs: 新增 `mail-log-diagnostics`；既有 6 個 capability 的需求不變。
- Affected code:
  - 新增 `Sources/CheAppleMailMCP/MailLog/`（日誌讀取、ndjson 解析、`formatString` 模板抽取、`APPENDUID` 比對器、輸出整形）
  - `Sources/CheAppleMailMCP/Server.swift`（工具定義與處理）
  - 新增測試於 `Tests/CheAppleMailMCPTests/`（合成 ndjson fixture、簡短輸出不含識別資訊的守門測試）
  - `Tests/CheAppleMailMCPTests/ToolCountCensusGuardTests.swift` 要求下列文件的工具數同步：`README.md`、`README_zh-TW.md`、`mcpb/manifest.json`、`server.json`
  - `CHANGELOG.md`
- 需要的權限：已實測在 Developer ID 簽章、hardened runtime、現有 `Entitlements.plist` 下，使用者位於 `admin` 群組時不需要新的 TCC 授權或 entitlement。**未驗證**：由 Claude Desktop 的 `.mcpb` 啟動、非 `admin` 使用者；依 `.claude/rules/deferred-live-verification.md` 以 `blocked-on-setup` 追蹤並在工具 description 加但書。
- 追蹤 issue：#465；相關：#463、#464、#405、#409；旁支：PsychQuant/issue-driven-development#355（`gh-egress.sh` 攔不到 email 與 Message-ID）。
