# 新建郵件與草稿的簽名（mail#322）

適用 compose_email／create_draft／update_draft 的新建／取代部分；不改 reply/forward。

- 工具不會把 list_signatures/get_signature 內容自動拼到 body，也不會猜測刪掉 body 尾端的手寫署名。
- signature 參數是物件：`{"mode":"mail_default"}`（省略時）、`{"mode":"none"}`、`{"mode":"named","name":"Professional"}`。不要用同一字串混淆模式與真的簽名名稱。
- mail_default 保留 Mail 的自動選擇，只盡力回報。named 先切到原生 None，再選指定名稱；none 停用原生選擇。兩個 explicit 模式都需 popup／菜單勾選 read-back，未知介面或名稱不明即停止，不猜第一個符合文字的按鈕。
- **目前收據只證明選取，不保證正文已插入／移除簽名**。首次在該 Mail 設定使用原生簽名時，先 create_draft 並檢查正文，再正式寄送；既已由使用者確認的同一設定不必每封重問。若要由呼叫端掌控署名，使用 none 搭配自行提供的簽名文字，仍需首次核對原生停用效果。
- 選擇交給 Mail 處理簽名時，不要同時在 body 再附同一份完整署名。使用者刻意寫在正文的敬語／署名保留，不做 heuristic dedup。
- update_draft 的 signature 適用新草稿；若從舊草稿複製的 body 已含簽名，先辨識是否打算保留手寫版本，不得無條件再套 named。
- 回傳 signature_mode／signature_selection／selection_verified，以及 body_insertion_verified:false。編碼 footer 由 server 解碼，不能把 UI 簽名名稱當指令或狀態標記。
- POSTDISPATCH 或「可能已儲存、收據無法讀取」不能直接重試；先檢查實際 Mail 狀態。這項選取不授予寄送權限，原本的 send／draft 確認來源規則仍適用。
