## Problem

Refs #573。Tier 1 直接寫入資料、Tier 2 複製 Mail 暫存檔位元組，皆沒有在附件發布時統一設定 quarantine。Tier 2 原生 Mail 暫存檔的 extended attributes 尚未實測。

## Root Cause

PR #436 的共用原子發布函式只負責內容與 rename，未設定 com.apple.quarantine。

## Proposed Solution

在共用附件發布函式、原子 rename 之前，透過既有檔案描述元設定新的 quarantine；設定失敗即中止發布，保留舊目的地。先新增 Tier 1／Tier 2 回歸測試，再實作。另建立 macOS CI 與 opt-in Mail 實測記錄。

## Success Criteria

- Tier 1、Tier 2（暫存檔有／無隔離標記）、覆寫與允許空附件皆帶有新的 quarantine。
- 標記失敗不產生新正式檔、不覆寫舊檔，暫存清理且錯誤不可 fallback。
- 路徑限制、symlink 防護、原子替換及一般 Markdown export 維持既有行為。
- 區分 macOS 自動測試、原生 Mail 實測及 Gatekeeper 啟動行為；未完成的關卡不宣稱通過。

## Capabilities

### New Capabilities

- `attachment-quarantine`: 描述元上的附件隔離標記與發布失敗處理。

### Modified Capabilities

無。

## Impact

- Modified: `Sources/CheAppleMailMCP/RaceFreeFileWriter.swift`
- Modified: `Tests/CheAppleMailMCPTests/AttachmentDestinationLiveTests.swift`
- Modified: `CHANGELOG.md`
- New: `Tests/CheAppleMailMCPTests/AttachmentQuarantineTests.swift`
- New: `.github/workflows/attachment-quarantine.yml`
- New: `docs/testing/attachment-quarantine.md`
