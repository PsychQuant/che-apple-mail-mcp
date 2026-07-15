# Tasks — require-wrapper-free-param

## 1. 核心（TDD）

- [x] 1.1 RED：`requireWrapperFreeRefusal(reason:)` 純函式測試（含 reason、四項替代、單訊息）+ #254 seam production-site 測試（strict+ineligible → throw 且 runner 零呼叫；strict+eligible+GUI 失敗 → propagate 且 runner 恰一次；default false → 現行後綴行為不變）— 落實 Wrapper-free strictness parameter requirement 三個 scenario
- [x] 1.2 GREEN：refusal helper + composeEmail/createDraft 兩站 strict 分支（router 之前 early-branch；router 本身不動）
- [x] 1.3 Server.swift：兩 tool inputSchema 增 `require_wrapper_free` + description 說明 + handler 解析傳遞；schema guard 測試更新

## 2. 文件

- [x] 2.1 CHANGELOG [Unreleased] Added
- [x] 2.2 `spectra validate require-wrapper-free-param` 通過
