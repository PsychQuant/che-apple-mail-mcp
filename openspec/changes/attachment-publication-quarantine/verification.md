# #573 驗證紀錄

日期：2026-10-28（Asia/Tokyo）。獨立草稿 PR：
[#584](https://github.com/PsychQuant/che-apple-mail-mcp/pull/584)。
依賴 PR #436 的 `0cc7d490e5aeed0c4f369acfbc589aed4cf1aff7`；沒有改寫 #436 分支。

## 測試先行證據

測試先提交於 `2540f1808a5d299c586b10de975e90418b98cb3d`。
第一次 [CI](https://github.com/PsychQuant/che-apple-mail-mcp/actions/runs/40697674325)
在 macOS 14.8.9／Swift 5.10 停於既有 MCP SDK 的 Swift 6.1 相依需求，
沒有執行測試，不算行為 RED。改用 macOS 15 runner 後，測試基準為
`391a9d730eec30165c3fe62c2a53d5889abf0546`，runtime source 與 #436 相同。

[RED CI](https://github.com/PsychQuant/che-apple-mail-mcp/actions/runs/40697870674)：
macOS 15.7.9、arm64、Swift 6.1.2；6 個測試、5 個預期失敗。
Tier 1、Tier 2 無標記 stage、Tier 2 有先前核准標記的 stage、空附件與 symlink
測試皆在正式檔的 fgetxattr 讀取回傳無 quarantine 時失敗。
一般 Markdown export 控制組通過。

合成來源的實際 xattr 輸出：

```text
Tier 2 synthetic stage, xattr -l:
com.apple.quarantine: 00c1;12345678;SyntheticSource;

Tier 2 synthetic stage, xattr -l:
[沒有屬性輸出]
```

這是 macOS 真實檔案系統上的合成 stage 證據，不是 Mail 原生產生的 stage。

## 修正後的 macOS 結果

[執行紀錄](https://github.com/PsychQuant/che-apple-mail-mcp/actions/runs/40698682620)，
測試提交 `a944c869d10284bb376287412395e7c9583fa341`；GitHub 的 PR merge checkout
為 `cd504a2d40365691ae8f0ba469f167a9763c36e5`。macOS 15.7.9（24G830）、
arm64、Swift 6.1.2。

| 檢查 | 結果 |
| --- | --- |
| AttachmentQuarantineTests | 9 項，0 failures |
| 既有附件／containment／RaceFreeFileWriter／SaveAttachment focused tests | 64 項，0 failures |
| 完整 swift test | 1,261 項，65 skipped，1 failure |

略過項目包含需明確 opt-in 的原生 Mail 測試、需要 Mail 執行中的測試，以及
runner 沒有 Envelope Index 的整合測試；不代表這些路徑已通過。

實際輸出如下；Foundation quarantine properties 解讀斷言也通過：

```text
Tier 1 published, xattr -l:
com.apple.quarantine: 0081;6ae1fc04;CheAppleMailMCP;
Tier 2 synthetic stage, xattr -l:
com.apple.quarantine: 00c1;12345678;SyntheticSource;
Tier 2 published, xattr -l:
com.apple.quarantine: 0081;6ae1fc04;CheAppleMailMCP;
Tier 2 synthetic stage, xattr -l:
[沒有屬性輸出]
Tier 2 published, xattr -l:
com.apple.quarantine: 0081;6ae1fc04;CheAppleMailMCP;
```

完整套件唯一失敗為既有
`SpecialMailboxesScriptBuilderTests.test_runScriptAsList_preservesEmptyStringPositions`：
MailController 的 Automation preflight 回報 Mail.app 未執行。該測試與 MailController
相對 #436 完全未修改。完整套件沒有全綠，不能省略此限制；未跳過、放寬該測試或
啟動 Mail 來掩蓋失敗。工作流程另在原始 PR base 重跑此案例，以區分既有環境限制。

[基準比對紀錄](https://github.com/PsychQuant/che-apple-mail-mcp/actions/runs/40699632896)：
提交 `360f85a42c89bc25095d3dcc18ef133a62043769` 僅增加 CI 診斷步驟，runtime 與
測試程式碼與上次相同。9 項新增與 64 項相關測試再次通過；完整套件仍為
1,261／65 skipped／1 failure。隨後同一 macOS runner checkout 未修改的
`0cc7d490e5aeed0c4f369acfbc589aed4cf1aff7`，單獨執行上述 pure-list 案例：
**1 項、1 failure，完全相同的 Mail.app 未執行錯誤**。因此這項失敗已在原始
基準實際重現；CI 整體維持 failure，沒有宣稱完整套件通過。

本次沒有變更既有的 Mail preflight 或該測試。完整套件全綠與原生 Mail 驗證仍
保留為未完成項目。Spectra validate 通過；analyze 無 Critical／Warning，只有
6 項補充具體範例的 Suggestion；git diff --check 通過。最後證據提交僅修改文件，
runtime 與測試內容保持上列已測提交不變。

## 修正與驗證範圍

修正提交：`a944c869d10284bb376287412395e7c9583fa341`。
`withAtomicAttachmentFile` 在 body 寫完、renameat 之前，以 fd 設定 fresh quarantine。
未修改 AttachmentDestination 的授權、canonicalization、no-follow traversal、
來源驗證或清理邏輯。Tier 1／Tier 2 都採預設 setter；一般 Markdown writer 不變。

故障測試注入 ENOTSUP、EPERM、EIO 以確認不發布與舊檔／屬性保存；另以真實
無效 fd 驗證 fsetxattr 的 EBADF 被保留。這不等於已測真實不支援 xattr 的磁碟。
來源／目的地 symlink 既有測試保留，新增外部哨兵 metadata 不變的行為測試。

終止錯誤的程式碼檢查：AttachmentDestination 兩個 catch 均包為
AttachmentDestinationError.io；Server 的 Tier 1 publish 位於取得資料的 fallback
catch 之外；Tier 2 的 retry 只處理特定 MailError。因此標記失敗不進入下載重試。
既有 AttachmentContainmentIntegrationTests 覆蓋目的地發布錯誤的終止行為。

## 尚待互動式 Mac 驗證

- 原生 Mail stage 的 xattr 與發布檔比較：未執行。本環境只有 Linux 編輯環境與
  GitHub macOS runner，沒有已授權、可互動操作 Mail 的 Mac。
- Gatekeeper 經 Finder／Launch Services 開啟附件的提示與屬性變化：未執行。
- #436 在 2026-09-17 的原生 staging 成功紀錄未量測本次 quarantine，不當成本次證據。
- 未執行完整 IDD ensemble，不宣稱獨立多代理審查通過。

已擴充 AttachmentDestinationLiveTests：先輸出 Mail stage 的 xattr -l，接著檢查
發布檔，並驗證後續刻意失敗不修改舊檔屬性。指令、合成信箱建立與清理方式見
`docs/testing/attachment-quarantine.md`。這些關卡未完成前保留 issue open、PR draft，
不合併、不部署、不標記 verified、不封存此 change。
