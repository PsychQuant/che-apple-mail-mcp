## Context

Mail.sdef 明確將 email addresses 定義為帳號已設定的地址清單；現有 list_accounts 也使用此來源。唯讀探測確認 EWS 可取得地址且原生帳號 ID 可對應 index，但目前原生探測每個帳號只回一個地址，未實測多別名設定；別名集合支援以合成 fixture 與 Mail 字典契約為依據。

## Goals / Non-Goals

**Goals:** 解決 EWS／已設定別名的身分來源與快取；維持訊息直讀及可見的降級。

**Non-Goals:** 不推定未設定的 SMTP From 能力、不更改帳號、不寫地址快取到磁碟、不自動觸發新 TCC 提示、不保證地址與歷史郵件共用原子快照。

## Decisions

### Counted JSON snapshot

固定 AppleScriptObjC 以 NSJSONSerialization 產出 version/count/accounts；每列只有 id、addresses、available，沒有密碼或其他設定。筆數／版本／欄位型別／ID 唯一性嚴格驗證。不可取得地址、空集合或無法完整 canonicalize 的帳號使 snapshot 不完整；已驗證的正向地址仍可使用。不要把登入 username 當成完整寄件地址來源。

### Bounded shared refresh

cache actor 保存 snapshot 與 monotonic 載入時間，成功 TTL=300 秒，失敗 backoff=60 秒。每次更新只有一個 loader task 與一個 5 秒 waiter deadline；逾時釋放所有 waiter、保留同一底層更新，後續呼叫先降級而不重啟。晚到成功可供下一次使用。取消只移除該 waiter；force refresh 略過有效快取／退避但不重複啟動既有 flight。原生工作沿用非 GUI subprocess 與 5 秒 interpreter timeout；caller 預算另外涵蓋 actor 排隊。

### Export confidence

成功 snapshot 取代舊 SQLite 集合，避免移除的地址被永久合併。只有 complete snapshot 且訊息帳號在集合內，非匹配才可自信判 received；部分 snapshot 的已知地址正向匹配仍可判 sent。完全不可用時沿用 SQLite primary 集合保留輸出，但包括正向匹配都標 direction_inferred，因未有完整原生設定證據。manifest 加 identity_source／identity_complete／可用時的 identity_cache_age_seconds，不包含地址清單。

## Implementation Contract

`opts.refresh_identity` 僅接受 boolean，預設 false。先驗證輸入與目的地，才更新 cache；等待後先檢查取消再進入匯出。`identity_source` 為 mail_account_cache 或 sqlite_primary_fallback；`identity_complete` 明示完整性，cache age 為 monotonic 年齡秒數。既有 skip_drafts、附件、dedup、日期、檔名政策保留。新 helper 使用已有 Automation grant；未授權／未判定／Mail 未運行時降級，不主動跳授權提示。

驗收需包含 strict parser、JSON escaping、EWS／alias sent、完整集合 external received、不完整及失敗推論、TTL／force／backoff／並行合併／取消／逾時晚到，以及完整 Swift suite。資料來源是已設定地址，不是永久所有權。

## Risks / Trade-offs

TTL 內設定改變 → 明確 refresh_identity 或等到到期。native 工作可能排隊 → 5 秒 caller wait budget 並保留單一 flight。來源失敗 → 不使用過期 snapshot 假裝 fresh，保留原有輸出但標示推論。GCD／系統排程非即時 → 不宣稱任意 OS 負載下的硬 SLA。

## Migration Plan

PR 完整驗證後由既有流程合併／部署；本次不自動執行。無資料遷移。

## Open Questions

Claude weekly quota 恢復後補完整 IDD ensemble。
