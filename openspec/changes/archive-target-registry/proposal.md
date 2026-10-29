## Why

#363 的歸檔目標只有人工清單，distributed_archives 看不到 index tombstone，造成已分派信件重抓。父子 filter 又不互相包含，需要保留各層搜尋及共同捕捉／分派規則。

## What Changes

- 新增 machine-level `~/.claude/.mail/archives.json`，記錄完整目標與顯式 parent。
- 提供列出／驗證／快照／分派規劃的可執行核心，跨層去重包含 index-only 歷史紀錄。
- archive-mail 串接全域預覽、上層 intake 捕捉、向下分派與失敗復原，不捨棄子層獨有候選。
- 未登錄維持既有 workflow；登錄樹內以 registry indexes 為準，外部 distributed archives 仍作額外只讀來源。

## Capabilities

### New Capabilities

- `archive-target-registry`: 全域目標模型、跨層快照、分派規劃與可復原執行。

### Modified Capabilities

無。

## Impact

plugin 的 Python helper、archive-mail SOP、registry command／schema 文件及暫存目錄測試；不改 Swift Mail runtime。開發不建立使用者 registry、不修改真實歸檔。
