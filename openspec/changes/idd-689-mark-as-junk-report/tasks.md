## 1. 測試先行（Tests/CheAppleMailMCPTests/MutationToolScriptBuilderTests.swift）

- [x] 1.1 寫 Example「report text by read-back」的測試：三列的回報文字逐字相等（Requirement: mark_as_junk reports the flag it read back and that it did not move the message）。驗證：帶標記 spec-example: junk-status-tool / report text by read-back，實作前編譯失敗或測試失敗。
- [x] 1.2 寫 Example「opposite read-back」的測試：讀回 true、要求 false 時丟出錯誤，訊息逐字相等（Requirement: mark_as_junk fails when the flag read back is the opposite of the request）。驗證：帶同名標記，實作前失敗。
- [x] 1.3 寫 Example「script shape and output parsing」的測試：script 先設定、再在 try 裡讀回、回傳讀到的值、不再含舊的固定字串；五種輸出的解析結果（Requirement: The mark_as_junk script reads the flag back without failing the call）。驗證：帶同名標記，實作前失敗。
- [x] 1.4 寫 Example「tool result through a fake script runner」的測試：經由 MailController 的測試接縫，三種 script 輸出各得到表中的結果。驗證：帶同名標記，實作前失敗。
- [x] 1.5 寫 Example「description text」的測試：mark_as_junk 的描述含三個詞（Requirement: The mark_as_junk description says it changes the flag only）。驗證：帶同名標記，實作前失敗。

## 2. 實作

- [x] 2.1 在 MutationToolScriptBuilder.swift 改 buildMarkAsJunkScript（設定後在 try 裡讀回、回傳 true／false／unknown），新增解析讀回值與產生回報的函式；MailController.markAsJunk 把 script 的輸出轉成回報或錯誤。驗證：第 1.1 到 1.4 項通過。
- [x] 2.2 改 Server.swift 裡 mark_as_junk 的描述，同步 mcpb/manifest.json 的同一段描述（REGENERATE_MCPB_MANIFEST=1 重新產生）與 README.md、README_zh-TW.md 工具表的那一列，並在 CHANGELOG.md 的 Unreleased 加條目。驗證：第 1.5 項通過，swift test 全數通過（含 ManifestToolsSetEqualityTests）。
