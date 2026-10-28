# 附件 quarantine 驗證（#573）

本修正依賴 [PR #436](https://github.com/PsychQuant/che-apple-mail-mcp/pull/436)，
基準為 `0cc7d490e5aeed0c4f369acfbc589aed4cf1aff7`。
獨立草稿 [PR #584](https://github.com/PsychQuant/che-apple-mail-mcp/pull/584)
以其 head branch 為 base；不更動 #436 的提交。

## 行為與相容性

Tier 1 與 Tier 2 在同一個附件原子發布點，使用開啟中的 sibling temp
描述元設定 `com.apple.quarantine`，成功後才 rename。來源 stage 的 extended
attributes 不會被複製；舊目的地的使用者核准狀態也不會沿用。
標記失敗（包含磁碟不支援 xattrs）會回報終止型目的地錯誤，保留舊目的地。
一般 Markdown export 不套用此政策。

標記採 `0081;<十六進位 Unix 秒數>;CheAppleMailMCP;`，沒有虛構的下載 URL、
Mail 代理名稱或 QuarantineEvents 事件 UUID。這是 raw xattr 格式的相容性選擇，
不是 Apple 公開穩定 API 對旗標位元的保證。測試同時檢查 raw xattr 與 Foundation
是否能辨識 quarantine properties。xattr 存在不代表所有啟動途徑都受 Gatekeeper
攔截，例如透過直譯器直接執行腳本不能由此推論。

Apple 的 [fsetxattr 說明](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsetxattr.2.html)
定義描述元操作與 ENOTSUP 等失敗；
[Foundation quarantineProperties](https://developer.apple.com/documentation/foundation/urlresourcevalues/quarantineproperties)
提供系統的屬性解讀。此處不用 path／URL setter，以維持 #436 的描述元安全邊界。
維持原有原子可見性；不新增斷電耐久性或 fsync 保證。

## macOS 自動測試

需要能建置既有 MCP SDK 的 Swift 6.1 或更新版本。

```sh
sw_vers
uname -m
swift --version
git rev-parse HEAD
swift test --filter AttachmentQuarantineTests
swift test --skip-build --filter 'AttachmentDestinationTests|AttachmentContainmentIntegrationTests|RaceFreeFileWriterTests|SaveAttachment'
swift test --skip-build
```

`AttachmentQuarantineTests` 以真實 fgetxattr 讀取結果，並執行 `/usr/bin/xattr -l`
輸出 Tier 1 正式檔，以及 Tier 2 的合成 stage／正式檔。測試涵蓋空檔、覆寫、
先前核准的 stage、symlink 父目錄與 leaf 交換、外部哨兵屬性、一般 export。
故障注入驗證共用發布點的錯誤清理，不代表已在不支援 xattr 的真實磁碟上測過。

`.github/workflows/attachment-quarantine.yml` 執行上述指令；沒有 Mail opt-in，
不操作真實信箱。第一次 macOS 14／Swift 5.10 執行停在依賴解析，不能算行為 RED。
修正前與修正後的執行紀錄見本 change 的 verification.md。

2026-10-28：macOS 15.7.9／Swift 6.1.2 上，9 項新增測試、64 項相關測試通過，
兩條發布路徑的 xattr -l 均顯示新的 quarantine。完整套件 1,261 項中 65 項略過、
1 項失敗：既有 pure-list 測試在 Automation preflight 要求 Mail.app 執行。
該失敗已在未修改的 #436 基準上單獨重現，未被略過或改成成功；完整證據見
[驗證紀錄](../../openspec/changes/attachment-publication-quarantine/verification.md)。

## 原生 Mail 實測：獨立關卡

使用 [既有合成本機信箱流程](attachment-staging.md) 產生並匯入唯一測試信，
不可改用私人郵件，也不需要寄信。在已授權 Mail Automation 的互動式 Mac 執行：

```sh
MAIL_APP_INTEGRATION_TESTS=1 CHE_MAIL_ATTACHMENT_FIXTURE_TOKEN=IDD402Native-UUID \
  swift test --filter AttachmentDestinationLiveTests
```

以實際產生的 token 取代範例。測試在 stage 清理前輸出 `Native Mail stage` 的
`xattr -l`，接著輸出 `Native Mail published copy`，斷言正式檔的 quarantine，
並確認第二次刻意失敗時舊檔的內容與屬性不變。記錄 macOS／Swift 版本、提交 SHA、
兩份原始 xattr 輸出與測試結果；stage 是否本來就有 quarantine 必須依該次輸出判定。
執行後依原流程移除唯一合成信箱，查核同名信箱數量為 0。

## Gatekeeper 與其他尚待驗證項目

如要驗證開啟時的系統行為，另使用自行產生、無副作用的可執行測試附件，
透過修正後的 save_attachment 儲存，再經 Finder／Launch Services 開啟；
記錄系統提示、OS 版本及開啟前後的 xattr。不要以惡意附件測試，也不要停用 Gatekeeper。
不以單純屬性存在或 `spctl` 對不支援檔案型別的回應宣稱所有啟動行為皆已驗證。

在原生 Mail 與啟動檢查完成前，#573／#584 保持 open／draft，不加 verified，
不以 #436 舊有原生 staging 通過紀錄替代本次 quarantine 驗證。
