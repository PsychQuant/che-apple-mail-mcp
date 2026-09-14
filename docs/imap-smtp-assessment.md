# IMAP APPEND 與直接 SMTP 架構評估（#308）

評估日期：2026-09-14。交付是可行性、代價與適用邊界的判斷，沒有新增傳輸程式、讀取憑證、連線認證或寄信。

## 建議

**目前不取代 mailto／paste，也不加入自動 fallback。** 若需求只是 rich body，優先評估整合 [#306 的 rich paste 實驗](rich-paste-experiment.md)，保留 Mail 的帳號與寄件備份流程。這仍需要產品化與驗證，並非已出貨 rich 支援。

只有在「不開 GUI、不依賴 Mail Automation／Accessibility」成為明確需求，且目標帳號可另行授權 IMAP／SMTP 時，才值得投入獨立、明確選擇的傳輸路徑。直接 SMTP 可以避開 Mail composer；APPEND 後仍請 Mail 開啟草稿再送，不能承諾同樣的零 GUI／TCC 效果。

這是根據目前需求與成本的建議，不是宣稱 APPEND 不可行。也不把「本次不導入」當成已完成未驗證的 runtime 工作。

## 五項評估的答案

| Issue 項目 | 評估結果 | 證據或剩餘界線 |
|---|---|---|
| #306 送出段 | 有歷史 HTML 組合的 Sent／實收通過報告 | 只支持 composer paste；不證明伺服器草稿載入 composer 的保真度 |
| 憑證取得 | 規劃使用者另行授權與本產品自己的 Keychain 項目 | 不依賴讀取 Apple Mail 的密碼／token；可用方式依供應商與管理政策決定 |
| 帳號覆蓋 | 本機 8 個啟用帳號中，5 IMAP、1 iCloud、2 unknown | 6/8 是類型候選；未認證、未確認 APPEND／SMTP 權限，不是 75% 已可用 |
| 既有工具關係 | 保留現行工具；若後續採用，新增明確選擇的 transport | 不在 GUI 失敗時暗中換帳號、憑證或傳輸方式，也不復活 body 注入 |
| Sent 記錄 | 可評估由供應商自動保存，或自行 APPEND 至已確認的 Sent | 必須處理重複、存檔失敗與寄送結果未知；補存失敗不能重新寄信 |

## 上游案例實際證明了什麼

核對 [apple-mail-fast-mcp PR #246](https://github.com/s-morgan-jeffries/apple-mail-fast-mcp/pull/246) 的 merged 狀態、說明與差異：2026-05-30 合併，新信、`send_now=False` 且已知寄件帳號時使用 IMAP APPEND。`draft_builder.py` 的實作呼叫 `set_content(body)`，支援附件與收件人欄位，**沒有建立 HTML alternative**。

該 PR 的送出、回覆與轉寄仍使用 AppleScript；說明把直接 SMTP 列為後續工作。它的裝置驗證是 iOS 草稿顯示，不是 APPEND 草稿經 Mail 開啟、寄送、實收後的完整 MIME 比對。不能把它當成 rich `multipart/alternative` 或直接 SMTP 已完成的證據。這個判斷只針對被 issue 引用的 PR，不推論該專案後續版本沒有新增能力。

本專案若自行建構 MIME，可以設計 plain／HTML alternative、附件、顯示名稱與各收件人欄位；這是待實作的能力，不能借用上游 plain 草稿測試算作驗證。

## 兩條不同的傳輸路徑

| 路徑 | MIME 控制 | 與 Mail 的關係 | 主要未知數 |
|---|---|---|---|
| 自建 MIME → APPEND Drafts → Mail 開啟／編輯／送出 | APPEND 前可控制；載入後可能改變 | 仍使用 Mail composer、帳號與 UI；自動操作可能需要 TCC | 載入轉換、編輯、附件、簽名、Bcc、送出後的 MIME |
| 自建 MIME → 直接 SMTP submission | 可控制提交內容；中繼仍可能改寫 | 不必操作 Mail；Sent 另行處理 | 認證、寄件身分、供應商政策、結果未知與 Sent 同步 |

[IMAP RFC 9051 §6.3.12](https://www.rfc-editor.org/rfc/rfc9051.html#section-6.3.12) 定義 APPEND 是將訊息加入信箱，不是投遞：它不傳 SMTP envelope。送出需要另外的 submission 路徑，例如 [RFC 6409](https://www.rfc-editor.org/rfc/rfc6409.html)。不能以 APPEND 成功回覆「已寄出」。

[#306 最後結果](https://github.com/PsychQuant/che-apple-mail-mcp/issues/306#issuecomment-5112852813)證明的歷史探針，是 Mail 自己的 composer 貼上後寄送。對 APPEND 路徑仍需測「伺服器原始 MIME → Mail 載入 → 存檔／再開啟 → Sent → 實收」，包含 HTML、CJK、附件、cc/bcc、寄件身分與簽名。沒有這項證據，不能取代現行 compose。

## 帳號覆蓋與憑證

本輪只讀取 Mail AppleScript 的 `account type` 和 `enabled`，輸出未含帳號名稱、位址、主機或憑證。8 筆均啟用：`imap` 5、`iCloud` 1、`unknown` 2、`pop` 0。本機 `/System/Applications/Mail.app/Contents/Resources/Mail.sdef` 宣告 `iCloud account` 繼承 `imap account`，因此歸為協定候選；這不等於第三方已獲准存取。

`unknown` 保留未知，不猜測為 Exchange。On-My-Mac 是本機儲存位置，不列入這 8 個遠端帳號的分母，也沒有可直接 APPEND 的伺服器信箱。POP 設定本身不提供 APPEND；若同一供應商另有可授權 IMAP 端點，需獨立設定。Exchange／EWS 連線同理：不能僅由 Mail 帳號類型推論 IMAP 已啟用或永久不可能啟用。

[Apple 的 Keychain ACL 文件](https://developer.apple.com/documentation/security/access-control-lists)說明項目存取由權限控制。Mail 已登入不代表另一個 binary 可讀取或重用其憑證。這次沒有嘗試讀取 Keychain；建議新功能自行管理使用者另行授權的憑證，以自身 Keychain 項目保存，處理撤銷與更新，不將密碼／token 放在 MCP 參數、日誌或版本控制。

供應商例子（文件於評估日核對，實際可用性仍需逐帳號確認）：

- [Gmail XOAUTH2](https://developers.google.com/workspace/gmail/imap/xoauth2-protocol)：有 IMAP／SMTP 的 OAuth 機制；新 client 仍需自己的授權與適用權限，不沿用 Mail 登入狀態。
- [Apple app-specific passwords](https://support.apple.com/en-us/102654)：適用的第三方登入可使用使用者建立的專用密碼；不能推論所有帳號／設定都適用。
- [Exchange Online SMTP AUTH](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/authenticated-client-smtp-submission)：支援 OAuth，且可受組織與信箱層級設定限制。IMAP 可用也不保證 SMTP submission 可用。

本 repo 的 `list_accounts`／`list_smtp_servers` 提供 Mail 設定資訊，不是可用的 IMAP／SMTP 認證客戶端。要新增 transport，需另外處理 TLS 驗證、OAuth／專用密碼生命週期與連線失敗分類，成本不只是新增 MIME builder。

## Drafts、同步與 Sent

[特殊用途信箱 RFC 6154](https://www.rfc-editor.org/rfc/rfc6154.html#section-2)的 `\Drafts`／`\Sent` 屬可選屬性，可能缺少或不只一個。應以伺服器回報及明確設定定位目的地；缺少／歧義時不能直接猜一個英文名稱。草稿 APPEND 使用 `\Draft` flag；成功只表示伺服器收下，不代表 Mail 本機已同步或可供現行數字 message-id 工具使用。

原 issue 的「約五分鐘未出現」是既有研究描述，本輪未重現；不能當成延遲上限。若另呼叫 Mail `synchronize`，又引入 Automation 依賴，仍不保證即時可見。新路徑需有自己的伺服器識別資訊與狀態回傳，不能拿 Mail 本機 row id 當成 IMAP UID。

直接 SMTP 的寄送 envelope 要與 MIME headers 分開：Bcc 收件人需存在 envelope，對外訊息不能洩漏完整 Bcc 名單。APPEND 草稿中的 Bcc 與 SMTP 對外 bytes 不能無條件共用；Sent 是否保留 Bcc 需明確定義本機／伺服器可見範圍。

建議的寄件備份政策：

1. 先確認供應商是否自行建立 Sent 副本，避免再 APPEND 一份造成重複。
2. 若需自行補存，使用已確認的 Sent 信箱，將 SMTP 提交與 Sent 存檔記為兩個階段；未確認提交成功不得把副本當作寄達證據。
3. SMTP 已接受但 Sent 存檔失敗，回報「提交已接受，備份待補」，只重試存檔，不重新寄送。
4. 若提交後連線中斷、結果不明，保留未知狀態並查核，不把逾時當成未寄出。Message-ID 可供關聯，不能單獨當成供應商的 exactly-once 保證。[SMTP RFC 5321](https://www.rfc-editor.org/rfc/rfc5321.html#section-4.2.5)描述提交回應的責任轉移；接受提交亦不等同最終收件端送達。
5. APPEND 確認遺失也可能造成重複，需記錄伺服器識別資訊並查核，不能盲目重放。

## 投入原型前的條件

這些是建議採用新 transport 時的前置工作，不是本輪已完成的功能：

- 確認需要解決的是無 GUI／TCC，或另有 Mail composer 無法滿足的需求；僅 rich body 先評估 paste 整合成本。
- 指定測試帳號、授權方式與可用協定，查明 Drafts／Sent、寄件 alias 權限與供應商自動備份行為。
- APPEND→Mail 路徑完成載入、編輯、送出、實收 fidelity 驗證；直接 SMTP 路徑驗證 envelope、Bcc、CJK、附件、錯誤分類與 Sent 補存。
- 建立遇到結果未知、使用者中途編輯與程序重新啟動時的續作／人工核對流程；清理須限定本次可證明擁有的產物。

本評估的建議是先不導入，保留上述條件作為未來重啟依據。未執行 APPEND／SMTP runtime 測試，不能據此宣稱某個帳號或任一路徑已可出貨。
