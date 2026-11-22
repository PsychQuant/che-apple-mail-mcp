## Why

2026-11-22 第一次對 iCloud 跑 `send_draft` 與 `append_draft`，兩個都在找草稿匣那一步停下：「the server marks no mailbox \Drafts」（#748）。程式用一般的 `LIST` 列信匣，只認伺服器標的 `\Drafts`／`\Sent`。iCloud 登入前的能力清單沒有 `SPECIAL-USE`，一般 `LIST` 沒有標 `\Drafts`，所以在 iCloud 上兩個工具都無法使用。登入後的能力清單、以及 `\Sent` 有沒有被標，都還沒觀察到。

## What Changes

- 找草稿匣與寄件備份匣改成一個封閉的順序：一般清單的標記；伺服器宣告 `SPECIAL-USE` 時明確再問一次；仍沒有就用 `direct-transport.json` 裡維護者寫的名稱（伺服器必須列出完全同名的信匣）；都沒有就拒絕。
- `direct-transport.json` 的帳號項目多兩個可省略的欄位：`drafts_mailbox`、`sent_mailbox`。
- 結果的 notes 說明每個信匣是由哪一條找到的；用設定檔的名稱也找不到時，拒絕訊息說明伺服器列了幾個信匣、是否宣告 `SPECIAL-USE`。拒絕與 notes 都不含信匣名稱或能力清單。
- 寄件備份匣與草稿匣是同一個信匣時，寄件副本階段留在 pending、草稿不移除（否則草稿會被當成自己的寄件副本，然後被刪掉）。

## Non-Goals

- 用信匣名稱推測（`Drafts`、`Sent Messages`…）。名稱只在維護者自己寫進設定檔時才算數。SwiftMail 的 special-use 查詢在伺服器沒宣告時會用名稱推測，所以那種伺服器不會被那樣問。
- 其他供應商的實測。只在 iCloud 上跑。

## Capabilities

### Modified Capabilities

- `direct-transport`：信匣的找法；設定檔的欄位。

## 前提

這次修改的三條 requirement 還在未封存的 `idd-742-send-draft-over-smtp`、`idd-744-append-draft-over-imap` 裡（`idd-745` 也改過 #742 的一條）。封存順序要是 742、744、745、748，748 的 MODIFIED 才會套在已合併的版本上；三條的全文是從 744（`send_draft`）與 742（設定檔、提交後階段）的最新版本複製後改寫的。

## Impact

- Affected specs: `direct-transport`（新增「The drafts and sent mailboxes are found in a fixed order」；修改設定檔、`send_draft`、提交後兩個階段三條）
- Affected code: `Sources/CheAppleMailMCP/DirectTransport/MailboxLookup.swift`（新）、`SwiftMailSession.swift`、`DirectTransportConfig.swift`、`SendDraftFlow.swift`、`SendDraftTool.swift`、`AppendDraftTool.swift`
- Tests: `MailboxLookupTests.swift`（新）、`DirectTransportConfigTests.swift`
- Docs: `README.md`、`README_zh-TW.md`、`CHANGELOG.md`、`mcpb/manifest.json`、`.claude/rules/direct-transport.md`
