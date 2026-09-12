## Context

messages.type 的草稿事實沒有進入 API。已提供的證據支持 5=草稿、0=一般信；目前 schema 也存在其他值，不能把未知值當 false。AppleScript 的現有列舉沒有同等判定來源。

## Goals / Non-Goals

**Goals:** 無逐封 headers MCP round-trip 的 nullable 草稿事實；匯出可明確排除草稿。

**Non-Goals:** 不猜信箱角色、不改 logical dedup 的代表 rowId、不推定未知 type、不重寫 #375 身分解析或 #376 信箱角色、不部署／操作真實歸檔、不在此改 plugins#127 預設。

## Decisions

### Nullable draft fact

`is_draft` 一律出現，true／false／null 分開。SearchResult 使用 Bool?，SQL 只接受已知 integer 0／5。reader 初始化時偵測 type 欄位一次；沒有則投影 NULL，維持舊 schema 可查。summary 的 flag 與 MIN(ROWID) 代表列一致；ids/count 不增加欄位。AppleScript fallback 加 null，沒有新 headers IPC。

### Explicit export exclusion

`opts.skip_drafts` 預設 false，保留既有匯出；所有 manifest item 都揭露 is_draft。true 時在 fetch/body/attachment 之前查狀態：true → skipped＋skip_reason=draft；null 或查詢失敗 → error＋draft_status_unknown。只有 false 可繼續。type 查詢錯誤必記 stderr，不靜默當 false。拒絕非 boolean 選項，避免誤把字串 true 當未啟用。

### Existing archive compatibility

不變更日期、檔名、direction、dedup、attachments 與 ids/count 的語意。初始 output directory／lock 的建立仍依既有流程；被排除的項目不取得內容也不產生 Markdown／附件。此 option 是 API 能力；consumer 採用需明確設定 true，null 不能自行當成非草稿。

## Implementation Contract

新增結果欄位及選項如上。SQLite schema 缺欄、NULL、非 integer、未知 numeric type 均 null；不由 mailbox 推導。查無 id 依既有錯誤路徑回報，匯出嚴格選項下不繼續 fetch。manifest status 的 skipped 計數可含草稿，skip_reason 用於辨別；unknown 計入 errors。Test fixtures 必須涵蓋 All Mail 草稿副本、普通 Drafts-named folder、MIN-row provenance、unknown 與無內容讀取；完整測試、工具 manifest 同步與獨立 review 才可 verified。

## Risks / Trade-offs

strict summary consumers 原先要求五欄 → 更新規格與測試並揭露六欄。unknown 不等同非草稿 → 明確 JSON null 及 strict export per-item error。讀到狀態後 Mail 本身仍可能變化 → API 是讀取時觀察值，不宣稱持續身分或快照隔離。既有 default export 可包含草稿 → manifest 揭露，預設相容決策與 opt-in 在工具說明明寫。

## Migration Plan

提交 PR；既有 caller 可繼續原預設，需排除草稿者設定 skip_drafts=true 並處理 unknown errors。無資料遷移或自動部署。

## Open Questions

完整 IDD ensemble 等待 Claude weekly quota 恢復。
