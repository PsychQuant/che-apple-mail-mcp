# 建立信件：wrapper-free 優先（#175 / #237）

> **嚴重性（CRITICAL）：對正式信件產生 cite-block 是嚴重缺陷，不是美觀小問題。**
>
> 用 `compose_email` / `create_draft` 建**正式信件**時若讓 body 被包成
> `<blockquote type="cite">`（wrapped body），**等同把整封信的本文在行動端顯示成「被引用內容」**——
> 對長輩、上位者、跨機構的正式往來，這是失禮、失專業的錯誤，不可當「桌面端看不出來就沒差」帶過。
> **絕不可靜默接受 wrapped body**：要嘛滿足下方 eligibility 走乾淨路徑，要嘛在寄出前**明確告知使用者
> 這封會被 wrap、由使用者拍板**。看到 result string 有 `[legacy path — …]` 後綴卻沒揭露就送出 = 嚴重違規。

## 規則

用本 MCP 的 `compose_email` / `create_draft` 建立**正式信件**時，**優先滿足 wrapper-free
mailto path 的 eligibility**；做不到時必須**明知並揭露**取捨，不可靜默接受 wrapped body。

背景：Mail.app 對任何 AppleScript-injected body 在 MIME-serialization 時包
`Apple-Mail-URLShareWrapperClass` → `<blockquote type="cite">`（#175 runtime 證實、
不可事後剝除）。桌面端被 inline style 隱藏、**寄件人看不出異狀**，但許多行動端 client
會把整封信的本文顯示成「被引用內容」— 正式信件的觀感問題。唯一乾淨路徑是 Mail 原生
editor（mailto: hand-off + 鍵盤快捷鍵），即 #175 的 wrapper-free path。

## Eligibility（全部成立才走乾淨路徑）

| 條件 | 不滿足時 |
|------|----------|
| `format` = `plain`（或省略） | markdown/html → legacy → wrapped |
| subject 非空 | 空 subject → legacy（GUI 視窗識別靠 title）|
| **不帶 `from_address`** | 自訂寄件人 → legacy → wrapped（**#237 實證的日常 trigger**；乾淨化根治 = #219）|
| **收件人用 bare address（不帶 display name）** | 帶 `Name <addr>`（含中文人名）→ legacy → wrapped（mailto RFC 6068 只載 addr-spec、載不了人名，是**與 `from_address` 獨立的第二個 trigger**；乾淨化根治 = #277）|
| Accessibility 已授權（`check_accessibility`）| 未授權 → legacy |
| env `CHE_MAIL_DISABLE_MAILTO_COMPOSE` 未設 | 設了 → legacy |

`#237` 之後，legacy 路徑的 result string 會揭露 path + 具名 reason；看到
`[legacy path — …]` 後綴就代表這封信的 body 已被 wrap，**要在寄出前決定接受與否**。

## 常見情境 recipe

### 要從非預設帳號寄（最常見，#237 的 trigger）

**不要**直接帶 `from_address`。改用兩段式：

1. `create_draft(...)` **省略 `from_address`**（其餘 eligibility 滿足）→ 乾淨草稿落在預設帳號
2. 請使用者在 Mail 撰寫視窗**手動點寄件人下拉選單**切換帳號 — 原生 GUI 動作，不觸發 wrapper

> ⚠️ **手動切帳號本身是 footgun**：若使用者忘記切，這封信就從**錯的預設帳號**寄出（本機預設帳號未必是預期的寄件身分，屬不可逆的誤寄）。所以第 2 步務必**明確提醒使用者切換並在寄出前確認寄件人**。此 footgun 的乾淨化根治 = #219（verified sender-popup + 讀回驗證，自動選帳號、不再靠手動）。

只有在「使用者明確接受 wrapped body 換自動選帳號」時才帶 `from_address`（result 會有揭露後綴）。

### 要顯示收件人人名（`Name <addr>`）

帶 display name 的收件人**獨立觸發** legacy → wrapped（見 eligibility 表）。目前「乾淨 body」與「顯示人名」**二選一**：走乾淨路徑就得用 bare address（Mail 通常會自動從 Contacts 補顯示名）。**若同時又要非預設帳號**，三者（乾淨 body + 人名 + 指定帳號）目前無法並存——這正是逼出上面手動 footgun 的根源。乾淨化根治 = #277（+ #219）。在兩者都修好前，若使用者堅持要顯示人名，依頂部 CRITICAL：**明說這封會被 wrap、由使用者拍板**，不可靜默送出。

### 要附件

附件不影響 eligibility（走 GUI ⇧⌘A 注入），但 **CJK / 全形符號路徑有 #220 卡死風險**。
含中文/全形「」路徑的附件：優先「乾淨草稿（不帶 attachments）+ 使用者手動拖曳檔案」。
ASCII 路徑可正常帶 `attachments`。

### 要 rich text（markdown/html）

目前結構上不可能 wrapper-free（mailto 只載 plain）。二選一並明說：
(a) 降級 plain 走乾淨路徑；(b) 接受 wrapped body 換 rich text。

## 違反偵測

- Result string 出現 `[legacy path — …]` 卻沒有向使用者揭露/確認 → 違反本規則
- `Tests/CheAppleMailMCPTests/ComposeDisclosureGuardTests.swift` 掃 schema 描述必含警告
- Reply/forward 的對應規範見 #218（native-verb + paste）；cite artifact 殘留議題見 #229

## 來源

- #175 — wrapper RCA + mailto 乾淨路徑（closed）
- #237 — from_address 靜默降級的實證 + 三處揭露落地（本規則的直接動機）
- #219 — custom-sender 乾淨化根治（open）
- #277 — display-name recipients 乾淨化根治（open；與 #219 互補，兩者都修好 clean body + 人名 + 指定帳號 才能並存）
- #220 — CJK 附件路徑 GUI 卡死（open）
