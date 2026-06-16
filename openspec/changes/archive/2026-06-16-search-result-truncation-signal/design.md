## Context

`search_emails` / `list_emails` 的 SQLite fast path 把結果用 `LIMIT ?` 截斷後以裸 JSON array 回傳，沒有任何「還有更多」的信號。LLM-driven consumer（含本 repo 的 `export_emails_markdown` 大量歸檔）拿到剛好 `limit` 筆時會誤判為完整集合而漏信。Gmail 同一封信在 inbox/Archive/All Mail 多個 mailbox 重複出現，更容易把命中數推過 limit。

## Goals / Non-Goals

**Goals**
1. 呼叫端能**確定性**偵測 truncation（非 `==limit` 啟發式偽陽性）。
2. 信號形狀對既有「case 回傳 formatJSON 字串」架構零摩擦。
3. 每個 result element 欄位不變（沿用既有 backward-compat 契約）。

**Non-Goals**
1. Offset / cursor 分頁（pull 完整集合）。
2. `total_matched` 總命中數（需額外 COUNT 查詢）。
3. 改動 search 的 filter / sort / field 語意。

## Decisions

### D1. 確定性偵測 = 內部抓 `limit + 1`

**選**：SQL `LIMIT ?` 綁 `limit + 1`，回傳前 `limit` 列，`truncated = (fetched > limit)`。
**捨**：(a) `truncated = (returned == limit)` 啟發式 — 對「剛好等於 limit」的完整集合會偽陽性；(b) 另跑 `COUNT(*)` 取總數 — 多一次查詢、且總數非必需。
**理由**：`limit+1` 多抓一列、成本可忽略（ORDER BY + LIMIT 已有 index），但把 truncation 從「可能」變「確定」。是用最小代價換正確性的經典做法（同 keyset pagination 的 `LIMIT n+1` 慣例）。

### D2. Response = envelope `{ results, returned, limit, truncated }`

**選**：search_emails / list_emails 回傳物件 envelope；`results` 仍是原 result 陣列、每個 element 欄位不變。
**捨**：(a) 維持裸 array + 第二個 MCP content block 傳 truncated — 與「每個 dispatch case 回傳單一 formatJSON 字串、由中央 wrapper 包成單一 `.text`」的架構衝突，需重構 return path；(b) 只在 truncated 時換成物件、否則裸 array — 形狀不一致更難消費。
**理由**：envelope 完美貼合既有 `return formatJSON(x)` pattern（case 只是改傳的物件，不動 wrapper），是最小 blast radius。對 LLM-consumed MCP tool，envelope 比裸 array 更清楚。spec 既有的 "result format backward compatibility" requirement 規範的是**每個 result element 的欄位**（不刪欄位），envelope 包一層不違反其意圖。
**Breaking note**：response 形狀由 array → object 是 breaking change，但已在 spec delta + tool description 明示；ecosystem consumer（archive-mail skill、export 流程）改讀 `.results` 即可。

### D3. AppleScript fallback 一致包 envelope（best-effort truncated）

**選**：SQLite 不可用時的 AppleScript fallback 路徑也回傳同一 envelope；但 fallback 無法 `limit+1`，`truncated` 採 `returned == limit` best-effort 啟發式，tool description 標明「fallback 的 truncated 為啟發式」。
**理由**：形狀一致比「兩條路徑不同形狀」好；fallback 是 no-FDA 的罕見退化路徑，啟發式 truncated 已足夠提示。SQLite primary path（bug 觀察到的路徑）為確定性偵測。

## Risks

- Response 形狀 breaking → 由 spec delta + tool description + 測試鎖定；ecosystem consumer 一行改讀 `.results`。
- 要確保 search 的**所有 field 分支**（subject/sender/recipient/any）都套用 `limit+1`（綁定發生在共用 SQL 組裝處，單點修改即覆蓋）。
- 不可順手改 filter/sort 語意（scope 鎖在 truncation 信號）。
