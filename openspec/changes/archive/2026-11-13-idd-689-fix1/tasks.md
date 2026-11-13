## 1. 測試先行（Tests/CheAppleMailMCPTests/MutationToolScriptBuilderTests.swift）

- [x] 1.1 改 Example「report text by read-back」的測試：三列回報文字照新的 Example 逐字相等（Requirement: mark_as_junk reports the flag it read back and that it did not move the message）。驗證：帶標記 spec-example: junk-status-tool / report text by read-back，實作前失敗。
- [x] 1.2 改 Example「opposite read-back」的測試：錯誤訊息照新的文字逐字相等；另加一項，要求的值與讀回的值相同時不丟錯（Requirement: mark_as_junk fails when the flag read back is the opposite of the request）。驗證：帶同名標記，實作前失敗。
- [x] 1.3 改 Example「script shape and output parsing」的測試：is_junk 為 false 與 true 各比對整份 script，訊息參照恰好出現一次（Requirement: The mark_as_junk script reads the flag back without failing the call）。驗證：帶同名標記，實作前失敗。
- [x] 1.4 改 Example「tool result through a fake script runner」的測試：三列照新的開頭文字；測試接縫用 addTeardownBlock 清掉。驗證：帶同名標記，實作前失敗。
- [x] 1.5 改 Example「description text」的測試：描述含 flag only、issues no move、move_email，不含 stays there（Requirement: The mark_as_junk description says it changes the flag only）。驗證：帶同名標記，實作前失敗。

## 2. 實作

- [x] 2.1 改 MutationToolScriptBuilder.swift：buildMarkAsJunkScript 先把訊息解析成變數 msg，設定與讀回都用它；markAsJunkReport 照三種情況產生新的文字；修正註解裡「工具沒有查位置」的說法。驗證：第 1.1 到 1.4 項通過。
- [x] 2.2 改 Server.swift 裡 mark_as_junk 與 is_junk 的描述，重新產生 mcpb/manifest.json，同步 README.md、README_zh-TW.md 工具表的那一列，改寫 CHANGELOG.md 的條目（含「旗標沒有變就報錯」那一句）。驗證：第 1.5 項通過，swift test 全數通過（含 ManifestToolsSetEqualityTests）。
