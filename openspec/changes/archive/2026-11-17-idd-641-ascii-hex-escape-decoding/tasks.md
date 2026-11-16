## 1. 測試先行（RED）

- [x] 1.1 [P] A hex escape is two ASCII hex digits：`Tests/MailSQLiteTests/ByteDecodingTests.swift` 新增 `HexEscape.byte` 的單元測試（所有 ASCII 值，只有 `0-9A-Fa-f` 成為數字），兩個 quoted-printable overload、RFC 2047 `Q` 字與 `decodePercentEncoded` 的 Example 表各列。驗證：實作前編譯失敗或測試失敗。
- [x] 1.2 [P] `Tests/CheAppleMailMCPTests/MailControllerHtmlExtractionTests.swift` 新增 AppleScript 路徑的各列，含 `=ZZ` 保留 `ZZ`。
- [x] 1.3 [P] 新增守門測試：`Sources` 沒有 `radix: 16`。

## 2. 實作（GREEN）

- [x] 2.1 `Sources/MailSQLite/HexEscape.swift`，三個解碼器改用它，AppleScript 那一條在格式錯誤時只前進一個字元。驗證：1.1 到 1.3 通過，既有測試不變。

## 3. 文件

- [x] 3.1 `CHANGELOG.md` 條目。
