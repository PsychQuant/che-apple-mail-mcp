## 1. 可獨立完成的契約與資料層

- [x] 1.1 記錄「建立關聯證據先於正式接線」的候選 API、禁止的推論與 live gate；以設計內容核對 #405/#409 的反例及 Mail scripting dictionary，確認未把 mock 或未變快照當成 proof。
- [x] 1.2 建立「嚴格 wire 格式與狀態」的合法／破損 payload fixtures，供 Receipt payloads are strictly decoded 使用；以 fixture manifest 對照 found/not_found/ambiguous/unavailable 欄位集合與 wrong-scope 案例。
- [x] 1.3 實作 call-local receipt record 與嚴格 decoder，完成 Receipt payloads are strictly decoded 的格式／型別／scope 保證；以 DraftReceiptProtocolTests 驗證 malformed JSON、缺欄位、錯型別、未知版本／狀態／欄位、非數字 id、錯帳號均為 unavailable 且不回顯地址。此步不宣稱已取得 creation binding。

## 2. 實機證據與 adapter 關卡

- [ ] 2.1 完成 Creation adapter has live evidence before completion：先收尾 #405 專用 fixture，再於可操作桌面驗證同一 GUI 草稿確實重存、預設／明確 sender 與 competing drafts；留下 API、觀測值及失敗反例，決定可用 creation binding。未通過不得開始正式接線。
- [ ] 2.2 完成 Trusted creation context scopes the receipt：依 2.1 已驗證的 adapter 從本次 compose 取得 actual account 與 binding，不接受猜測；以 adapter tests 與受控 live 記錄確認 wrong-account／無 binding 不查地址。
- [ ] 2.3 實作「帳號範圍與建立前快照」，pre-create ID 依帳號分組且早於建立；以 scoped-baseline tests 驗證缺 baseline 不讀地址、不同帳號相同數字不互相污染，準備階段只讀必要 metadata。

## 3. 合併 receipt 與嚴格選擇

- [ ] 3.1 完成 One complete scoped read supplies identity and addresses：同一 script 在實際帳號範圍內完成 metadata 篩選、唯一 binding 匹配與 To/Cc/Bcc 讀取；以 reader tests 及 live collision fixture 驗證不讀不相關地址、所有 per-message 失敗均 fail closed。
- [ ] 3.2 實作「單次回讀與每次呼叫的結果」：create/update 共用一份 call-local outcome，移除額外 ID read 與 lastRecipientReceiptOutcome；以 spy 計數及 stale-outcome regression 證明每輪只有一個合併 read、失敗不重試、成功 not-found 最多三輪。
- [ ] 3.3 完成 Draft recipient receipt verifies addresses after save：所有草稿包含 bare／To-only 都驗證三個集合；以 recipient matrix tests 驗證 To-only 差異、mismatch 三欄 diff，以及 unknown 狀態不製造 found-address 差異。

## 4. 更新與對外契約

- [ ] 4.1 完成「刪除門檻與相容性」及 update_draft upsert tool：只用同一份 verified receipt 允許刪除，保留原稿 actual account／id／subject；以 phantom-create、old-row-resave、ambiguous、unavailable、delete-not-found fixtures 驗證不誤刪、不宣稱邏輯舊稿已消失。
- [x] 4.2 對齊 identify selector semantics 與 list_drafts returns draft ids 的 transient snapshot 指引；以 #405 no-mutation／description tests 驗證無 implicit selector fallback 且不承諾 subject 永久穩定。
- [ ] 4.3 更新 Server descriptions、manifest 及 receipt 文件，揭露三欄驗證、未確認不刪除與 snapshot 限制；以 registered-description tests 和 ManifestToolsSetEqualityTests 驗證一致，移除舊最大 id／兩份 receipt／寬鬆 parser 路徑。

## 5. 完整驗收與交付

- [ ] 5.1 以正常同主旨更新、跨帳號同主旨、舊稿重存、錯 To、部分讀取失敗及破損 payload 完成 end-to-end 驗收；執行完整 Swift suite、必要 mutation 與受控 Mail fixture，確認每個 scenario 有直接證據並收尾 fixture。
- [ ] 5.2 執行 spectra analyze／validate 與 IDD 獨立審查，修正實際缺陷；將 #409/#405/#427 各自要求與證據逐一對帳，所有 live gate 與接線完成後才標記 verified、更新 PR。
