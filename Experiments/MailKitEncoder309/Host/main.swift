import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let alert = NSAlert()
alert.messageText = "MailKit #309 實驗原型"
alert.informativeText = "這是未完成驗證的 Mail 擴充原型。開啟本程式不會寄信。啟用前請先閱讀同目錄 README；預設設定不處理任何信件。"
alert.addButton(withTitle: "關閉")
alert.runModal()
