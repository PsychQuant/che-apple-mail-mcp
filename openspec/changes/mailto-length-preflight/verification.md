## 驗證紀錄（2026-09-14）

- 精確計量與 builder 共用 ASCII unreserved 集合，按 UTF-8 bytes 計算；same recipient partition 涵蓋顯示名清單、to/cc/bcc、空清單與 header overhead。
- 六項 MailtoLengthTests 通過：CJK／emoji／combining／CRLF、全 ASCII、8000／8001、header-only overflow、三個 controller 的 no-script seam，以及真 Server 只讀工具 dispatch。
- 長度與既有 description guard 的九項針對性測試通過；舊六類斷言已明確更新為新增的第七類，不刪除 guard。（落地時疊在 #322 之上，長度改為第八類，斷言隨之改為八類。）
- 完整 swift test：**1,337 項、11 skip、零失敗**。第一次完整回歸只失敗於舊六類文字斷言，修正後重新完整執行通過。
- Codex 獨立靜態審查 PASS，沒有執行測試；最終測試由協調者執行。
- repo／plugin／global 三份規則逐項對帳 MAILTO_URL_TOO_LONG、check_compose_length、8000、手動貼上與明確批准拆信的指引。
- Global mirror：PsychQuant/che-claude-config PR #17，commit 36f2cee，基於 PR #15 的獨立 worktree。未修改使用者原 config 工作區，未部署。
- Spectra analyze 無 Critical/Warning，validate 通過；MCP census 與 manifest 為58個工具。

## 範圍與剩餘 gate

本 issue 實作 named preflight/refusal，不增加長正文傳輸、不改8000、不截斷／自動拆寄。header overhead 自己超限時會指向縮短subject／明確縮小recipient list，不能假稱清空body就能解決。fits=true 明示 other_requirements_checked=false。

沒有對真實 Mail 執行任何動作；no-side-effect refusal 以真 controller seam 驗證。Claude OAuth 尚待登入，四個 lens + DA 未完成，故尚非完整 IDD verified，PR 保留草稿。

## Landing and verify fixes (2026-10-29)

Landed on current main with 59 tools (main's 58 plus check_compose_length); the
numbers above are from the PR's older base. The IDD ensemble found that the contract
said create_draft always refuses an over-limit body, while the code (rightly, for the
maintainer's goal that the direct write handles every call) lets create_draft's direct
write take it: the length check runs only on the GUI path. The spec, change spec, both
rule copies, the create_draft and check_compose_length descriptions and the plugin
CHANGELOG now say so, a test pins that the direct result is returned without the GUI
path, and a structural test keeps the length check out of the create_draft case before
the direct write. When the direct write is enabled but not used, a refusal now carries
the reason it was not used (for example a missing from_address), and the length
refusal names the direct write as a route. Other fixes: check_accessibility counts
seven, the rule headers are closed lists again, ComposeRefusalTests covers the length
refusal, and the #304 citation in MailtoCompose.swift is restored.

## Verify round 2 (2026-10-29)

No HIGH; the loop stops here. The structural guard now covers the whole create_draft
case through the direct-write closure, five length identifiers, and the two
direct-write sources; a unit test passes a 9,000-character encoded body through
DirectDraft.eligibility and buildMessage. The length refusal names the direct write
only when the server runs with it, and only for calls that meet its conditions
(#486 wording, now in the #486 guard's runtime texts). "Before any Mail work" became
"before any GUI operation" (and before any Mail query for compose_email and
update_draft); the tool descriptions no longer tell callers to save the body to a
local text file. The global mirror (task 1.3) is updated once, after the chain is
restacked; until then the change spec's consistent-guidance requirement is unmet
there.

