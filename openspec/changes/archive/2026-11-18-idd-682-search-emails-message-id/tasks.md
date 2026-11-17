## 1. Tests first (RED)

- [x] 1.1 `Tests/MailSQLiteTests/MessageIDReadTests.swift`: the header-only reader equals `readEmail(...).messageId` on a fixture set (folded, encoded, duplicate, CR-only/LF-only/CRLF, no brackets, no header, header block longer than one chunk, bare-LF headers with a CRLF blank line in the body, a slice whose start index is not 0, very long lines); bounded read; unreadable cases. Verify: fails before the implementation.
- [x] 1.2 `Tests/MailSQLiteTests/SearchMessageIDTests.swift`: the lookup states (value / empty / unreadable), per-mailbox store-folder cache, `dedup: logical` kept row, rows keep their other fields.
- [x] 1.3 `Tests/CheAppleMailMCPTests/SearchMessageIDHandlerTests.swift`: through `executeToolCall`: flag off means identical rows and zero reads; flag on for `full` and `summary`; parity with `get_email` and the batch export on the same fixture; `ids`/`count` with the flag is an error; non-boolean is an error; schema and description text.

## 2. Implementation (GREEN)

- [x] 2.1 `EmlxFormat` shared prefix parse; `EmlxParser.readMessageID`; shared message-id helper used by `readEmail`.
- [x] 2.2 `MessageIDLookup` with the store-folder cache; `SearchResult.mailboxURL`.
- [x] 2.3 `Server.swift`: flag parsing, schema, description, row formatting, one stderr line per call.

## 3. Docs

- [x] 3.1 README search section and Performance table; CHANGELOG entry; tool description caveat about the outstanding live check.

## 4. Spec examples (#480)

- [x] 4.1 `include_message_id with ids or count is a parameter error`: `SearchMessageIDHandlerTests.testTheFlagIsRejectedForIdsAndCountAndWhenNotABoolean`
- [x] 4.2 `summary rows gain only message_id when the flag is set`: `SearchMessageIDHandlerTests.testOtherFieldsAreUnchangedWhenTheFlagIsOn`
- [x] 4.3 `message_id is absent from every row when the flag is off`: `SearchMessageIDHandlerTests.testWithoutTheFlagRowsAreIdenticalAndNoFileIsRead`
- [x] 4.4 `message_id equals get_email's for the fixture messages`: `MessageIDReadTests.testReaderEqualsTheWholeFileParseForEverySampleAndChunkSize`, `SearchMessageIDHandlerTests.testTheValueEqualsWhatGetEmailAndTheExportReport`
- [x] 4.5 `the three message_id states on four rows`: `SearchMessageIDTests.testThreeStatesAndTheRowsAreNeverDropped`
- [x] 4.6 `the omitted-key cases and their reasons`: `SearchMessageIDTests` (missing mailbox, header over the cap, value at the limit), `MessageIDReadTests.testALengthLineLongerThan4096BytesHasNoKeyWhileGetEmailHasAValue`
- [x] 4.7 `the read stops at the first blank line`: `MessageIDReadTests.testAnLFOnlyMessageIsReadNoFurtherThanTheChunkHoldingItsBlankLine`, `testABlankLineStraddlingAChunkBoundaryIsFoundForBothKinds`
