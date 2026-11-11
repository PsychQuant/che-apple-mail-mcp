## Summary

`dedup_strategy: last_archived` 的 run 不再把已經在 `output_dir` 頂層檔案裡的信再寫一份 `-N`（#652）。

## Motivation

`last_archived` 沒有 index，`known_ids` 是空的，Step 4.1 只看日期界線。讀不出日期的信一律當作較晚、保留（#600 的選擇），所以每次執行都重抓、Step 5 的 collision guard 每次都寫一份 `-N`。界線沒有推進時（SOP 從不自動推進），界線之後的每封信也一樣。Step 7 報了數量，但重複檔照樣累積。

## Proposed Solution

- 依維護者接受的預設（B1–B4）：`last_archived` 時，在 Step 5 之前對 `output_dir` 跑一次 `scan_report`，取 `usable` 的 Message-ID 成為「已歸檔集合」。`unparseable` 與 `synthetic_placeholder` 的檔案不加入。
- 集合寫成 skip file，放在目標 state 目錄（`.claude/.mail/state/archives/<slug>/`）底下用 `tempfile.mkdtemp` 新建的私有目錄（只有擁有者能讀、路徑不可預測，#635），交給 Step 5.0 的 `skip_message_ids_path`；Step 5.1 以 `get_email` 的 `message_id` 對同一個集合檢查。伺服器讀回時會不一樣的 id（行內有換行、前後有空白或 tab、以 `#` 開頭）不寫進檔案。
- Step 4.1：#643 讓 Step 3d 先補好 `message_id`，所以集合也併入 `known_ids`，已在頂層的信在 Step 4.1 就不是新信，預覽的數量是對的。skip file 仍保留，作為伺服器用真正 Message-ID 做的第二道檢查。
- Step 7 報出因頂層已有而沒有重寫的封數、掃描的檔數與秒數（B4：大型 target 的成本在使用中量測）；掃描跑不了時寫一行說明這個缺口。
- 改寫承諾 `-N` 重複的句子（Step 4.1 #600 段落、`is_after_watermark` docstring、Step 7 的日期讀不出那一行）與 `plugin/CLAUDE.md` 的 `dedup_strategy` 列。

## Non-Goals

- 不讀子目錄或分散到別處的檔案：「已歸檔」只由 `output_dir` 頂層目前的檔案決定（#652 Residue）；被移走的信會再歸檔一次。
- 不改伺服器，不擴大 allowed roots。
- `index` 與 `both` 不變（它們有 index）。

ASSUMPTION: skip file 所在的 state 目錄在伺服器 allowed roots 之外時，伺服器拒絕整批呼叫，照 Step 5.0 既有的「整批失敗」規則退回 Step 5.1，Step 5.1 仍用同一個集合檢查，所以不會因此重寫。

## Alternatives Considered

- 只在 Step 5.1 檢查（B1 的第二個選項）：批次路徑沒有檢查，被否決。
- 讀不出日期就停止（B1 的第三個選項）：會讓 AppleScript fallback 路徑的每次執行都停下，被否決。

## Impact

- Affected specs: `archive-mail-dedup`（ADDED requirement）
- Affected code: `plugin/commands/archive-mail.md`（Step 4.1 dedup recipe 與呼叫、Step 5.0、Step 5.1、Step 7、Step 8.5 掃描段落、日期 recipe 的 `is_after_watermark` docstring）、`plugin/CLAUDE.md`
- Tests: `plugin/tests/test-archive-mail-recipes.py`
- Docs: `plugin/CHANGELOG.md`（Unreleased）
