## Why

#700 的 verify 第 1 輪指出寄出後確認的幾個問題：未確認訊息裡有一句叫人從那個視窗再寄一次；輪詢看的是這次呼叫期間出現的所有視窗，Mail 自己開的檢視視窗會讓正常的寄出被回報成未確認；`forward_email` 的描述沒有限定「帶 body」；等待時間的進位、check 本身出錯時的回報、手動關閉視窗的情況沒有寫進規格；live 但書被寫成永久的 requirement；測試的標記對不上它們的 Example。

## What Changes

- 輪詢只看寄信按鍵落下的那個視窗：按鍵前一刻的 front window，id 在剛確認它屬於這次呼叫的同一個 `tell` 裡讀出。
- 未確認訊息不再叫呼叫端寄信；只指向那個視窗與 sheet，並說明視窗還在不代表沒寄出。
- `forward_email` 的描述限定為帶 body，並寫明不帶 body 的轉寄沒有這個確認（#731）。
- requirement 補上：等待時間向上進位到 0.5 秒的倍數且至少檢查一次；check 本身出錯時照既有的 post-dispatch 訊息回報；手動關閉視窗與寄出無法分辨；live 但書是暫時的。新增等待時間的 Example。
- `CHE_MAIL_MAILTO_STEP_DELAY` 不再管寄信按鍵之後的等待，寫進 CHANGELOG。

## Non-Goals

- 關掉確認的開關。這個確認依賴的假設要靠 live 驗證處理（#700 保持開啟）。
- 不帶 body 的轉寄（#731）、`compose_email`（#730）。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `message-composition`：MODIFIED Requirement: A reply or forward is reported as sent only after its compose window has closed。

## Impact

- Affected specs: `message-composition`
- Affected code: `Sources/CheAppleMailMCP/AppleScript/ComposeScriptBuilder.swift`、`Sources/CheAppleMailMCP/TimeoutOutcomeHint.swift`、`Sources/CheAppleMailMCP/Server.swift`
- Tests: `Tests/CheAppleMailMCPTests/SendConfirmedByWindowCloseTests.swift`
- Docs: `README.md`、`CHANGELOG.md`、`mcpb/manifest.json`、`.claude/rules/timeout-outcome-boundary.md`
