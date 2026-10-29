## Context

messages.type 的草稿事實沒有進入 API。已提供的證據支持 5=草稿、0=一般信；目前 schema 也存在其他值，不能把未知值當 false。AppleScript 的現有列舉沒有同等判定來源。

## Goals / Non-Goals

**Goals:** 無逐封 headers MCP round-trip 的 nullable 草稿事實；匯出可明確排除草稿。

**Non-Goals:** 不猜信箱角色、不改 logical dedup 的代表 rowId、不推定未知 type、不重寫 #375 身分解析或 #376 信箱角色、不部署／操作真實歸檔、不在此改 plugins#127 預設。

## Decisions

### Nullable draft fact

`is_draft` 一律出現，true／false／null 分開。SearchResult 使用 Bool?。驗證後改為：本列或同 global_message_id 的任一副本是 type 5 或帶 Mail 的草稿 flag（0x40）→ true；type 0、沒有上述證據、本列與副本都不在名稱是草稿匣的信箱 → false；其餘 null。只看 type 不夠：從伺服器或其他裝置同步下來的草稿存成 type 0，常在帳號的草稿匣裡。信箱名稱只用來收回 false，從不當成草稿的證據（維護者決定，2026-10-28）。reader 初始化時偵測欄位一次（schema 在 reader 存活期間不變）；沒有 type 則投影 NULL，維持舊 schema 可查；沒有 flags 或 global_message_id 時不回 false。信箱名稱是資料、不是 schema：由連線上註冊的 SQL 函式 `che_drafts_folder(url)` 在每次查詢時判斷，reader 開啟後才建立或改名的草稿匣也會被看見。summary 的 flag 與 MIN(ROWID) 代表列一致；ids/count 不增加欄位。AppleScript fallback 加 null，沒有新 headers IPC。

### Explicit export exclusion

`opts.skip_drafts` 預設 false，保留既有匯出；所有 manifest item 都揭露 is_draft。true 時在 fetch/body/attachment 之前查狀態：true → draft_skipped＋skip_reason=draft（另有 drafts_skipped 計數，不混進 Message-ID 去重的 skipped）；null 或查詢失敗 → error＋draft_status_unknown（查詢失敗時附上原因）。只有 false 可繼續。type 查詢錯誤必記 stderr，不靜默當 false。拒絕非 boolean 選項，避免誤把字串 true 當未啟用。

### Existing archive compatibility

不變更日期、檔名、direction、dedup、attachments 與 ids/count 的語意。初始 output directory／lock 的建立仍依既有流程；被排除的項目不取得內容也不產生 Markdown／附件。此 option 是 API 能力；consumer 採用需明確設定 true，null 不能自行當成非草稿。

## Implementation Contract

新增結果欄位及選項如上。SQLite schema 缺欄、NULL、非 integer、未知 numeric type 均 null；不由 mailbox 推導。查無 id 依既有錯誤路徑回報，匯出嚴格選項下不繼續 fetch。草稿排除用自己的 status 與計數，skipped 仍只代表 Message-ID 去重；unknown 計入 errors。Test fixtures 必須涵蓋 All Mail 草稿副本、普通 Drafts-named folder、MIN-row provenance、unknown 與無內容讀取；完整測試、工具 manifest 同步與獨立 review 才可 verified。

## Risks / Trade-offs

strict summary consumers 原先要求五欄 → 更新規格與測試並揭露六欄。unknown 不等同非草稿 → 明確 JSON null 及 strict export per-item error。讀到狀態後 Mail 本身仍可能變化 → API 是讀取時觀察值，不宣稱持續身分或快照隔離。既有 default export 可包含草稿 → manifest 揭露，預設相容決策與 opt-in 在工具說明明寫。

## Migration Plan

提交 PR；既有 caller 可繼續原預設，需排除草稿者設定 skip_drafts=true 並處理 unknown errors。無資料遷移或自動部署。

## Open Questions

完整 IDD ensemble 已在 2026-10-28 的 landing commit 上執行（報告在 #374）。草稿匣名稱清單只涵蓋常見語系；不在清單內的語系仍可能讓這類草稿被報成 false。
