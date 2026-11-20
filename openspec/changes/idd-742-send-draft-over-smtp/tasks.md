## 1. 最低系統與相依（第一個 PR，不改行為）

- [ ] 1.1 `Package.swift`：最低系統改為 macOS 26；加入 `SwiftMail`（釘 1.17.0 的 commit）。
- [ ] 1.2 `Package.resolved` 納入版本控制（從 `.gitignore` 移除）。
- [ ] 1.3 `README.md`、`README_zh-TW.md` 的系統需求與徽章；`CHANGELOG.md` 的 BREAKING。
- [ ] 1.4 `make test` 全過；release 的 universal binary 建得出來並能啟動；把編譯時間與 binary 大小記到 issue。

## 2. 測試（RED）

- [ ] 2.1 設定檔：不存在、讀不懂、欄位缺少或超出列舉（Requirement: Direct transport is available only for accounts configured for it）。
- [ ] 2.2 憑證：項目不存在時拒絕並點名命令列模式；密碼不出現在結果與 stderr（Requirement: The credential comes only from the server's own keychain item）。
- [ ] 2.3 參數與選草稿：清單以外的參數、兩個選擇器都給或都沒給、零封與多封、不在伺服器上（Requirement: send_draft sends one existing draft and cannot write content）。
- [ ] 2.4 提交前的五項檢查，照順序（Requirement: A draft is checked before it is submitted）。
- [ ] 2.5 去掉 Bcc：摺行、多個 Bcc、不是 CRLF、`Resent-Bcc`；其餘位元組不變（Requirement: The submitted message is the draft without its Bcc fields）。
- [ ] 2.6 提交的三種結果與紀錄的狀態，含 `attempting` 被讀成 `unknown`（`spec-example: direct-transport / submission outcomes`）。
- [ ] 2.7 提交之後的階段與補做（`spec-example: direct-transport / stages after submission`）。
- [ ] 2.8 工具描述的但書（Requirement: send_draft states that it has not been run against a real server）。

## 3. 實作（GREEN）

- [ ] 3.1 Direct transport is available only for accounts configured for it — 設定檔的讀取與驗證。
- [ ] 3.2 The credential comes only from the server's own keychain item — keychain 的讀取；`--direct-transport-set-credential`。
- [ ] 3.3 連線層的協定與 SwiftMail 的實作（IMAP 的資料夾、找草稿、取信、APPEND、刪除；SMTP 的提交）。
- [ ] 3.4 The submitted message is the draft without its Bcc fields — 去 Bcc 與信封位址。
- [ ] 3.5 A submission has one of three outcomes — 已寄出紀錄（先寫再送）與結果分類；`--direct-transport-forget`。
- [ ] 3.6 The sent copy and the draft's removal are separate stages after submission — 補存、移除與補做。
- [ ] 3.7 send_draft sends one existing draft and cannot write content — 工具本身、封閉的參數、`.send` 類別；A draft is checked before it is submitted 的五項檢查。
- [ ] 3.8 send_draft states that it has not been run against a real server — 工具描述與 `mcpb/manifest.json`。

## 4. 文件與規則

- [ ] 4.1 `.claude/rules/direct-transport.md`：憑證、結果、紀錄的界線；`r-must-direct-db.md` 與 `timeout-outcome-boundary.md` 各補一段。
- [ ] 4.2 `README.md`、`README_zh-TW.md`：設定步驟與工具列表；`CHANGELOG.md`。

## 5. 實際驗證（要維護者同意，issue 在這之前保持開啟並貼 `blocked-on-setup`）

- [ ] 5.1 維護者設好設定檔與憑證；用只寄給自己的草稿跑一次，記下每個階段的結果與伺服器的回覆。
- [ ] 5.2 觀察 iCloud 是否自動保存寄件備份、是否回報 `\Drafts`／`\Sent`、是否支援以 UID 刪除單封，據此定 `sent_copy` 的建議值。
