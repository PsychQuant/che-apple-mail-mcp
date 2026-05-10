## 1. Spec coverage (Gap B)

- [x] 1.1 在 `openspec/specs/message-composition/spec.md` 新增 Requirement 區塊「Markdown mode honors opt-in URL scheme allowlist via `sanitize_links`」(connect to existing requirements at the same heading depth `### Requirement:`),內容對應 change delta `specs/message-composition/spec.md` 的 ADDED Requirements,包含 5 個 scenarios (default-off passthrough、`sanitize_links=true` 阻擋 javascript:、allowlist 保留、no-op in plain/html、wiring contract end-to-end)。**Verification**: `grep -c "Markdown mode honors opt-in URL scheme allowlist" openspec/specs/message-composition/spec.md` 回 ≥ 1; `spectra validate sanitize-links-spec-coverage --strict` 通過; `grep -c "sanitize" openspec/specs/message-composition/spec.md` 從 0 變 ≥ 5 (Requirement title + 4 scenario titles minimum)。

## 2. Wiring contract test (Gap A)

- [ ] [P] 2.1 在 `Tests/CheAppleMailMCPTests/MailControllerComposeTests.swift` 新增 `testBuildComposeEmailScript_sanitizeLinks_blocksJavaScriptURL` test, 對 markdown body `[click](javascript:alert(1))` 呼叫 `buildComposeEmailScript` 兩次:`sanitizeLinks: false` 時 produced AppleScript 必須含 `href="javascript:`,`sanitizeLinks: true` 時必須**不**含。**Verification**: 加 fault injection — 把 `MailController.composeEmail` 內 `sanitizeLinks: sanitizeLinks` 改成 `sanitizeLinks: false`,re-run test 必須 fail; 還原後 `swift test` 全綠 (309 → 310)。
- [ ] [P] 2.2 對 `buildCreateDraftScript` 新增同形 test `testBuildCreateDraftScript_sanitizeLinks_blocksJavaScriptURL`,涵蓋 default-off / sanitize_links=true 兩臂。**Verification**: fault injection on `MailController.createDraft` 的 sanitize_links forwarding 必須讓 test fail; 還原後 `swift test` 全綠 (310 → 311)。
- [ ] [P] 2.3 對 `composeReplyHTML` (透過 `buildReplyEmailScript` 產生 AppleScript) 新增 test `testBuildReplyEmailScript_sanitizeLinks_blocksJavaScriptURL`,使用 `userBody: "[click](javascript:alert(1))"`、`userFormat: .markdown`,涵蓋兩臂。**Verification**: fault injection on `MailController.replyEmail` sanitize_links forwarding 或 `composeReplyHTML` sanitize_links forwarding 必須 fail test; 還原後 `swift test` 全綠 (311 → 312)。
- [ ] [P] 2.4 對 `buildForwardEmailScript` 新增同形 test `testBuildForwardEmailScript_sanitizeLinks_blocksJavaScriptURL`,涵蓋兩臂。**Verification**: fault injection on `MailController.forwardEmail` sanitize_links forwarding 必須 fail test; 還原後 `swift test` 全綠 (312 → 313)。

## 3. Validation + CHANGELOG

- [ ] 3.1 跑完整 `swift test` confirm 313 passing / 0 failing / 8 skipped (基準 309 + 4 new wiring tests)。**Verification**: command output 顯示對應 counts; 新增 test 全部出現在 pass list。
- [ ] 3.2 在 `CHANGELOG.md` `## [Unreleased]` 區塊加一行記錄 spec coverage + wiring contract tests (#85),不加 count metric (per cluster A 學到的反 rotting 教訓)。**Verification**: `grep -F "#85" CHANGELOG.md` 至少 1 hit; 新增的行不含「N tests」之類數字; 風格與相鄰 [Unreleased] entries 一致。
- [ ] 3.3 跑 `spectra validate sanitize-links-spec-coverage --strict` 通過 (specs delta 對齊 ADDED Requirement、tasks 涵蓋 Requirement title)。**Verification**: command exit code 0; output 不含 Critical / Warning。
