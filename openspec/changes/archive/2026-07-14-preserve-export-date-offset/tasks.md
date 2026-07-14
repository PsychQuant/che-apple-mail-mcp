# Tasks — preserve-export-date-offset

## 1. Helper（TDD — 先 RED 後實作）

- [x] 1.1 RED：`EmailMarkdownRendererTests` 新增 offset 測試 — `Mon, 13 Jul 2026 16:49:57 +0800` → `2026-07-13T16:49:57+08:00`；`-0530` → `-05:30`；`+0000` → `Z`；named zone（`GMT`）→ 現行 UTC 輸出；不可解析 → passthrough。驗證：filter 測試 RED（現行輸出 `Z`）
- [x] 1.2 GREEN：`rfc822ToISO8601UTC` 更名 `rfc822ToISO8601` 並改為 offset-preserving（parse 成功後抽 `[+-]\d{4}` token → 輸出 formatter 用該固定 offset + `ZZZZZ`；無 numeric token → UTC；parse 失敗 → passthrough）；兩個呼叫點（renderer :51、export :361）同步更名。驗證：filter 測試 GREEN
- [x] 1.3 既有 pin `Z` 格式的測試盤點與更新（`grep -rn "T.*Z\"" Tests/ | grep -i "date\|iso"`）— 只更新受 offset 變更影響者，fallback 案例維持原斷言。驗證：全套件 0 failures

## 2. 一致性驗證（Server-side markdown export requirement 的 MODIFIED 條款落地驗證）

- [x] 2.1 filename 日期測試：`+0800` 跨午夜案例（UTC 日 ≠ local 日，如 `Mon, 14 Jul 2026 00:30:00 +0800` = UTC 07-13 16:30）→ filename 以 `2026-07-14`（sender-local）開頭。驗證：filter 測試綠
- [x] 2.2 frontmatter/manifest/filename 三處同源一致性：export 整合測試斷言三者由同一 helper 輸出推導（frontmatter date 的 `prefix(10)` == filename 日期），落實 Server-side markdown export requirement 的 MODIFIED date/filename 條款與新 scenario。驗證：filter 測試綠

## 3. 文件

- [x] 3.1 `CHANGELOG.md` [Unreleased] Fixed：offset 保留 + 兩個 trade-off（混合 offset 字串排序、跨午夜 filename 位移與 re-export 冪等說明）。驗證：內容審閱
- [x] 3.2 `spectra validate preserve-export-date-offset` 通過。驗證：命令輸出 valid
