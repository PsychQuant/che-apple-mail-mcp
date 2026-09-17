# #309 MailKit encoder 探測原型

**狀態：隔離實驗，尚未在 Mail 啟用或寄送驗證。** 不屬於 MCP 產品、Package.swift、release 或安裝流程。產物可拋棄；保留原始碼是為了讓後續探測可重現，不代表採用此架構。

## 目前能回答的問題

本機 Xcode SDK 的 `MEMessageEncoder.h` 明確區分兩個 callback：

- `getEncodingStatus` 在寄件人／收件人變動時提供可簽章／加密狀態，影響 Mail 的操作介面。
- `encode` 在送出時處理訊息。未簽章、未加密且沒有錯誤時，文件說結果中的 **data** 會被忽略。

`MEMessageEncodingResult` 另有 `signingError`／`encryptionError`；不能把前述條件擴張成「所有 result 都忽略」。`MEEncodedOutgoingMessage.rawData` 可包含完整訊息，但不代表任何任意資料都會被 Mail 採用。`isSigned`／`isEncrypted` 描述結果狀態，並非通用的排版開關。

建議目前不要將這個 API 採為一般 unsigned body 替換機制。這是依契約的判斷，**不是已跑出的 runtime FAIL**。若要探測真正的簽章路徑，還需簽章身分、正確簽章產物與收件端信任／顯示的實測；本原型沒有假設 `true` 本身會產生有效簽章，也沒有實作該分支。

[Apple MEMessageEncoder](https://developer.apple.com/documentation/mailkit/memessageencoder)、[WWDC21：Build Mail app extensions](https://developer.apple.com/videos/play/wwdc2021/10168/)說明這是訊息安全擴充及其介面／寄送階段。可控制編碼不等於提供建立、定位或自動送信 API，因此不能據此保證整個 MCP 工作流程零 GUI／TCC。

## 本原型如何工作

`ProbeHost` 是承載 appex 的 AppKit app，沒有寄信功能。`EncoderProbe` 只提供 `MEMessageSecurityHandler`。兩個設定預設為空，故預設不處理任何信件：

- `PROBE_RECIPIENT`：明確確認的測試信箱裸位址。
- `PROBE_RUN_ID`：新產生的 UUID；程式正規化為大寫。

只有主旨完全等於 `IDD309-<UUID>`、寄件人與唯一收件人皆符合該位址、沒有 Cc/Bcc，才屬於候選。`encode` 若被呼叫且有完整 rawData，會在 header/body 分隔後，將**唯一一次** `IDD309_ORIGINAL_<UUID>` 改成 `IDD309_REPLACED_<UUID>`。只接受單一 `text/plain`、7bit（可省略）、UTF-8／US-ASCII（可省略 charset）且正文實為 ASCII 的訊息；拒絕 multipart、附件 disposition、簽章 headers、其他 transfer encoding。其餘 bytes 與 headers 保持原樣；找不到、重複、缺分隔或超過 1 MiB 一律回 nil result。

結果固定 `isSigned=false`、`isEncrypted=false`，不建立假簽章。只記錄靜態事件，不記錄主旨、信箱或 raw MIME。兩個狀態能力均為 false，Mail 可能根本不呼叫 encode；這種情況必須列為「未進入分支」，不能判定 data 被忽略。

這是觀察 unsigned 資料是否被採用的原型，不會自行移除 cite wrapper。即使 byte replacement 被採用，也只證明這個條件下的替換；不能直接宣稱 wrapper 消失或有效簽章路徑通過。

## 本機建置與測試

需要 Xcode 與 `xcodegen`。App／appex 的最低建置目標是 macOS 13，測試 target 為 macOS 14（目前 SDK 的 XCTest 下限）；本輪沒有在最低版本實測。在本目錄執行：

```sh
./build.sh
```

產生的 `.xcodeproj`、plist、entitlements 與 `.build` 忽略於 Git。建置設定預設禁止簽章；Xcode build 預設會暫時註冊 app 到 LaunchServices，`build.sh` 的退出清理會撤銷這個確切產物的註冊，並確認 LaunchServices dump 不再含該路徑（清理未完成則失敗）；不要把直接執行 xcodebuild 當成完全沒有註冊副作用。沒有複製到 Applications、啟用 Mail extension 或寄信步驟。未簽章建置成功不代表 Mail 會載入。

測試涵蓋：設定預設禁用、精確匹配與自寄限制、唯一正文替換、保留 headers、拒絕缺失／重複／過大輸入、multipart／附件／簽章／不支援的 transfer encoding，以及真實 MailKit result 物件保留 unsigned bytes。最後一項只驗證資料承載物件，**不會呼叫 Mail 的送出路徑**。

## 尚未執行的 Mail 驗收

需另行確認測試信箱、允許安裝／啟用的環境及實際測試寄送，並以合適的開發簽章建置。簽章與 Mail 啟用是不同於本機 build 的步驟，不因本 README 的存在而已獲執行授權。

| 項目 | 目前狀態 | 足夠的證據 |
|---|---|---|
| SDK／官方文件契約 | 已閱讀 | 明確的 unsigned/no-error data 忽略條件，與 errors 分開 |
| 原型本機建置與輸入限制 | 見 issue 的本輪實測紀錄 | build／tests 日誌 |
| Mail 是否呼叫 unsigned encoder | 未測 | 候選訊息的 callback 事件，不以 carrier 測試代替 |
| Mail 是否忽略 replacement | 未測 | 已有 returned-unsigned-replacement 事件後，比對 Sent／實收原始 MIME 的兩個 marker |
| errors 對整個結果／送出流程的影響 | 未測，原型未提供 error 模式 | 獨立明確的 error-case 實驗，不從無錯誤分支外推 |
| 有效簽章分支與收件端可見後果 | 未測、未實作 | 真正簽章產物及收件端驗簽／顯示；不能只有 isSigned=true |
| wrapper 是否消失且格式保留 | 未測 | 基準、修改後 Sent／實收 MIME 與格式核對；本 byte marker 原型尚不足以回答 |

人工驗收流程：先設定唯一 UUID／自寄位址，簽章、安裝並手動啟用後，在 Mail 建立全新 synthetic 郵件，填入精確主旨和原 marker；先存草稿確認內容，再於已確認的測試寄送中觀察 callback，分別收集 Sent／實收 MIME。沒有 `returned-unsigned-replacement` 事件就不能判定此分支的資料採用行為。實收查找需涵蓋垃圾郵件夾。

可讀取本原型的靜態事件（沒有信件內容）：

```sh
log show --last 10m --style compact \
  --predicate 'subsystem == "org.psychquant.experimental.encoder309"'
```

資料若是 base64、quoted-printable、multipart、HTML 或附件形式，原型直接拒絕；符合單一 7bit plain 形式但沒有唯一連續 marker，也會拒絕替換；這是探針不適用，不是 Mail 忽略資料。驗收期間若使用者改了收件人／主旨，必須重新核對。完成後手動停用擴充，只清理本次確認的測試信，不能以廣泛主旨搜尋刪除其他信件。

後續若確定投入真正簽章原型，需另行設計明確限制的測試模式；目前不能以未完成的 signed 分支宣布 #309 成功或失敗。
