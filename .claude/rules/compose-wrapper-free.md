# 建立信件：正式信件絕不帶 cite-block（#175 / #237 / #220）

> **嚴重性（CRITICAL）：正式信件的 body 絕不可被包成 `<blockquote type="cite">`。無例外。**
>
> wrapped body **等同把整封信的本文在行動端顯示成「被引用內容」**——對長輩、上位者、
> 跨機構的正式往來，這是失禮、失專業的錯誤，不可當「桌面端看不出來就沒差」帶過。
>
> **「揭露後由 agent 自行判定可以接受」這個逃生門已於 2026-08-10 移除**（#220 重開的直接原因）。
> 揭露是**報告**，不是**許可**。看到 result string 有 `[legacy path — …]` 後綴 = **那封信不能用**。

## 強制作法：正式信件一律帶 `require_wrapper_free: true`

這是本規則唯一的機械執行點，**不是建議**：

```jsonc
create_draft({ to, subject, body, format: "plain", require_wrapper_free: true })
```

帶了它，clean path 不可用時工具會**直接 fail 並具名原因**，不會產出已污染的草稿。
不帶它 = 把「會不會被 wrap」交給運氣，而失敗模式是**寄件人自己看不出來**（桌面端被
inline style 隱藏）——這正是它必須是預設的理由。

## 唯一合法的處置順序（clean path 不可用時）

1. **調整參數滿足 eligibility** —— 降 `format: plain`、`compose_email` 改成 `create_draft`、
   把不合格的部分（非 ASCII 附件、bcc 人名）拆掉。
2. **拆掉的部分改由使用者手動補** —— 拖曳附件、手動切寄件帳號。這些是 Mail 原生 GUI 動作，
   不觸發 wrapper。
3. **兩者都不行 → 停下來，不要建立那封信。** 把取捨講清楚交給使用者決定。
   **破例只能由使用者明說；agent 不得自行以「我已揭露」為由接受 wrapped body。**

## 規則

用本 MCP 的 `compose_email` / `create_draft` 建立**正式信件**時，**必須**滿足 wrapper-free
mailto path 的 eligibility；做不到時依上方三步處置，**不得**產出 wrapped body 的成品。

> ⚠️ **跨 repo 呼叫時本規則不會自動載入。** 本檔住在 che-apple-mail-mcp 的
> `.claude/rules/`，從別的 repo（Academic、教學、任何專案）呼叫本 MCP 時**看不到它**——
> 那裡只看得到 tool description 的事後揭露，沒有事前禁令。2026-08-10 的實際事故即由此發生。
> 對應的全域鏡像規則在 `che-claude-config/rules/common-mail-compose.md`；**修改本檔時一併更新它**。

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

ASCII 路徑可正常帶 `attachments`（走 GUI ⇧⌘A 注入，不影響 eligibility）。

**含中文／全形符號路徑的附件：一律建「乾淨草稿（不帶 `attachments`）」+ 請使用者手動拖曳檔案。**
這是**必須**，不是「優先」——#220 把非 ASCII 路徑判為 mailto-ineligible，帶了就靜默落 legacy、
body 被 wrap。**不要為了省使用者三秒的拖曳而交出一封 wrapped 的正式信。**

> 2026-08-10 事故：明知本節存在仍帶 `attachments` 呼叫（中文檔名的申請表），拿到揭露後
> 直接交件。**「優先」這個詞是漏洞** —— 它讓「這次比較方便」成為可辯護的偏離。故改為必須。

不要用「複製到 ASCII 暫存路徑」規避：附件在收件人端顯示的就是那個 ASCII 檔名，對方看不懂
收到什麼。檔名的可讀性優先於省一次拖曳。

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

- **正式信件呼叫未帶 `require_wrapper_free: true`** → 違反本規則（不論結果是否剛好乾淨）
- Result string 出現 `[legacy path — …]`，而該草稿仍被交付／送出 → 違反本規則
  （揭露不是許可；見頂部 CRITICAL）
- 非 ASCII 附件路徑仍帶 `attachments` 呼叫 → 違反本規則
- `Tests/CheAppleMailMCPTests/ComposeDisclosureGuardTests.swift` 掃 schema 描述必含警告
- Reply/forward 的對應規範見 #218（native-verb + paste）；cite artifact 殘留議題見 #229

## 來源

- #175 — wrapper RCA + mailto 乾淨路徑（closed）
- #237 — from_address 靜默降級的實證 + 三處揭露落地（本規則的直接動機）
- #219 — custom-sender 乾淨化根治（open）
- #277 — display-name recipients 乾淨化根治（open；與 #219 互補，兩者都修好 clean body + 人名 + 指定帳號 才能並存）
- #220 — CJK 附件路徑 GUI 卡死（**2026-08-10 重開**：原「legacy + 揭露」取捨在真實對外正式信件上失效）
- #304 — **移除 legacy compose path（結構解，open）**。本規則是 #304 落地前的行為約束；
  legacy path 一旦移除，wrapped body 在結構上不可能發生，本規則的多數條文即可退役。
  **規則叫 agent 別走某條路，遠弱於把那條路拆掉。**
