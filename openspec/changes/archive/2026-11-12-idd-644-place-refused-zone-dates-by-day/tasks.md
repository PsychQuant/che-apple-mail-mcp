## 1. 測試先行（RED）

- [x] 1.1 [P] A date whose zone cannot be read is placed by its day：`ArchiveThreadOrderTests.test_refused_zones_are_placed_by_their_day` 帶標記 `spec-example: archive-mail-thread-order / thread order with refused zones`，跑三列並對所有排列檢查結果相同。驗證：實作前失敗。
- [x] 1.2 [P] `test_bounds_ignore_day_placed_values` 帶標記 `spec-example: archive-mail-thread-order / bounds ignore day-placed values`。驗證：實作前失敗（目前已通過的列也照列）。
- [x] 1.3 SOP 守門：rebuild Step 6 的報告行、rebuild Step 4 與 view Step 4 的說明。驗證：實作前失敗。

## 2. 實作（GREEN）

- [x] 2.1 日期 recipe 的 `thread_sort_key`、`thread_order`、`thread_bounds`。驗證：1.1、1.2 通過，既有 `ArchiveThreadOrderTests` 維持綠。
- [x] 2.2 `archive-mail-rebuild-threads.md` Step 4、Step 6 與 `archive-mail-view.md` Step 4 的說明。驗證：1.3 通過。

## 3. 文件

- [x] 3.1 `plugin/CHANGELOG.md` Unreleased 條目，寫明 rebuild 可能重排含這類日期的 thread。驗證：內容審閱；plugin 測試全綠。
