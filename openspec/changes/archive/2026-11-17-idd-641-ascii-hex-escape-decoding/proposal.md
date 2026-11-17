## Summary

三個解碼器只把 `=` 或 `%` 後面「兩個 ASCII 十六進位字元」當成跳脫；其餘一律照字面保留（#641）。

## Motivation

`RFC822Parser.decodeQuotedPrintable`、`MailController.decodeQuotedPrintable`、`MIMEParser.decodePercentEncoded` 都用 `UInt8(hex, radix: 16)` 解析跳脫，而這個初始化接受正負號：`=+5` 變成位元組 0x05，`=-0` 變成 NUL，`%+5` 變成 0x05。AppleScript 那一條在跳脫格式錯誤時還會吃掉後面兩個字元，`=ZZ` 只剩 `=`。`Character.isHexDigit` 不能拿來修，它接受全形數字（`＝０５`）。

## Proposed Solution

- 依維護者 2026-11-11 接受的預設：`MailSQLite` 提供一個 `public` 的 `HexEscape.byte(_:_:)`（兩個 `Character` 換成位元組，只接受 `0-9A-Fa-f`），三個解碼器都用它；`Sources` 裡不再有 `radix: 16`，一條守門測試掃它。
- `MIMEParser.decodePercentEncoded` 一併納入（同一個根因）；帶正負號的 `%+5` 和其他格式錯誤的 `%` 一樣回 nil。
- AppleScript 那一條在格式錯誤時補上 `=`、只前進一個字元，`=ZZ` 保留 `ZZ`。

## Non-Goals

- 不改軟換行、行尾截斷與大小寫（小寫 `=c3=a9` 照舊解碼）。
- 不改其他沒有 `radix: 16` 的解碼路徑。

## Impact

- Affected specs: `hex-escape-decoding`（新）
- Affected code: `Sources/MailSQLite/HexEscape.swift`（新）、`RFC822Parser.swift`、`MIMEParser.swift`、`Sources/CheAppleMailMCP/AppleScript/MailController.swift`
- Tests: `Tests/MailSQLiteTests/ByteDecodingTests.swift`、`Tests/CheAppleMailMCPTests/MailControllerHtmlExtractionTests.swift`、新的守門測試
- Docs: `CHANGELOG.md`
