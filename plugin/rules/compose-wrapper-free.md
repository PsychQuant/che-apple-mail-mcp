<!-- Imported from the server repo's .claude/rules/compose-wrapper-free.md
     (che-apple-mail-mcp). That copy is CANONICAL — it evolves with the server
     (issue #s below refer to PsychQuant/che-apple-mail-mcp). This plugin copy
     exists so plugin users get the discipline without cloning the repo; re-sync
     it when the upstream rule changes materially. Imported by plugin-upgrade,
     shell v2.43.0. -->

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
| ~~不帶 `from_address`~~ **#219 已根治**：自訂寄件人走 clean path（GUI 驅動 From popup + read-back 驗證；mismatch → legacy fallback，寄件帳號保證正確、body wrapped + 揭露）| Accessibility 未授權 → legacy（popup 需 GUI scripting）|
| ~~收件人用 bare address~~ **#277 部分根治（draft-only）**：`create_draft` 的 display-name To/Cc 走 clean path（視窗開啟後 GUI clipboard 填入、Mail 原生 tokenize；bcc 必須 bare）；`compose_email`（send）帶人名仍 → legacy（fill 失敗會缺收件人寄出，故 send 不冒此險）| send 帶人名 / bcc 帶人名 / Accessibility 未授權 → legacy |
| Accessibility 已授權（`check_accessibility`）| 未授權 → legacy |
| env `CHE_MAIL_DISABLE_MAILTO_COMPOSE` 未設 | 設了 → legacy |

`#237` 之後，legacy 路徑的 result string 會揭露 path + 具名 reason；看到
`[legacy path — …]` 後綴就代表這封信的 body 已被 wrap，**要在寄出前決定接受與否**。

## 常見情境 recipe

### 要從非預設帳號寄（#219 已根治 — 直接帶 `from_address`）

**#219 之後**：直接帶 `from_address` 即可——clean path 以 GUI 驅動 From popup 選帳號並 **read-back 驗證**（popup 顯示值必含該 address），任何 mismatch 自動 fallback legacy（`set sender` 帳號正確 + wrapped body + 揭露），**絕不從錯帳號寄出**。以下兩段式手動流程保留為 Accessibility 未授權機器的 workaround：

#### （僅 Accessibility 未授權時）舊兩段式 workaround

（此機器 Accessibility 未授權時，帶 `from_address` 會直接走 legacy → wrapped。要乾淨 body 只能兩段式：）

1. `create_draft(...)` **省略 `from_address`**（其餘 eligibility 滿足）→ 乾淨草稿落在預設帳號
2. 請使用者在 Mail 撰寫視窗**手動點寄件人下拉選單**切換帳號 — 原生 GUI 動作，不觸發 wrapper

> ⚠️ **手動切帳號是 footgun**：忘記切 = 從錯的預設帳號寄出（不可逆誤寄）。第 2 步務必**明確提醒切換並在寄出前確認寄件人**。根治路徑是開啟 Accessibility 讓 #219 popup 生效。

### 要顯示收件人人名（`Name <addr>`）— #277 draft-only 根治

**`create_draft`（草稿）**：直接帶 `Name <addr>` — clean path 在視窗開啟後以 clipboard 填 To/Cc（Mail 原生 tokenize；CJK 人名走 paste 避開 IME，#220 教訓）。限制：bcc 必須 bare address；**存檔後在草稿裡確認 To/Cc**（GUI fill 的 read-back 有限，live 驗證為 #277 residue）。三合一（乾淨 body + 人名 + 指定帳號）在 draft 上已可並存（#219 + #277）。**`compose_email`（直接寄送）**：帶人名仍走 legacy（fill 失敗會缺收件人寄出——send 不冒此險）；要 send 且要人名，依頂部 CRITICAL 明說 wrap、由使用者拍板。

### 要附件

附件不影響 eligibility（走 GUI ⇧⌘A 注入），但 **CJK / 全形符號路徑有 #220 卡死風險**。
含中文/全形「」路徑的附件：優先「乾淨草稿（不帶 attachments）+ 使用者手動拖曳檔案」。
ASCII 路徑可正常帶 `attachments`。

### 要 rich text（markdown/html）

目前結構上不可能 wrapper-free（mailto 只載 plain）。二選一並明說：
(a) 降級 plain 走乾淨路徑；(b) 接受 wrapped body 換 rich text。

## TCC fallback ladder（#287 — Automation 未授權時怎麼辦）

cite-block 迴避有三階，依 TCC 授權狀態選：

| 階 | 路徑 | TCC 需求 | 附件 | body |
|----|------|----------|------|------|
| (a) | `create_draft` / `compose_email` wrapper-free clean path | Automation + Accessibility | ✅（GUI ⇧⌘A） | 乾淨 |
| (b) | **`open_mailto`（LaunchServices，#287）** | **零** | ❌（RFC 6068；手動拖入） | 乾淨（mailto compose 天生無 wrapper） |
| (c) | legacy AppleScript 注入 | Automation | ✅ | **被 `<blockquote type="cite">` 包 — 正式信件不可用** |

**鐵律：AppleScript 工具回 `-1743`（Not authorized to send Apple events）時，(b) 是正解，絕不落到 (c)。**

-1743 的授權路徑（**實證修正 2026-07-21，#288**）：signed MCP binary **自持 Automation 授權**——TCC identity 綁 binary 簽章身分（#211 FDA 教訓的 Automation 軸），**與終端機 app 分開**。實測：shell `osascript` 能控制 Mail（Terminal 的授權）而 binary 仍 -1743 —— 兩個獨立 TCC 主體，**osascript 可用 ≠ binary 已授權**。處置：

- 系統設定 → 隱私權與安全性 → 自動化 → 找 **binary / 其 host** 的 entry（Claude Desktop extension → Claude.app 底下）勾選 Mail
- **找不到 entry** = 先前的 Deny 被記住、macOS 不會重新跳 prompt → `tccutil reset AppleEvents` 後重觸發任一 Mail 工具
- 授權 per-install；binary 更新可能使 entry 失效（同 #211）

(b) 的已知限制：視窗開在**系統預設**郵件 app（未必是 Mail.app）、附件帶不了。

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
