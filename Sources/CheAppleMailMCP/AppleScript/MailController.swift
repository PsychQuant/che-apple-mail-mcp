import Foundation

/// Controller for Apple Mail via AppleScript
actor MailController {
    static let shared = MailController()

    private init() {}

    // MARK: - AppleScript Execution

    /// Execute AppleScript and return result
    func runScript(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw MailError.scriptCreationFailed
        }

        let result = script.executeAndReturnError(&error)

        if let error = error {
            let message = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown AppleScript error"
            let code = error["NSAppleScriptErrorNumber"] as? Int ?? -1
            throw MailError.scriptFailed(message: message, code: code)
        }

        return result.stringValue ?? ""
    }

    /// Execute AppleScript and return result as list
    func runScriptAsList(_ source: String) throws -> [String] {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw MailError.scriptCreationFailed
        }

        let result = script.executeAndReturnError(&error)

        if let error = error {
            let message = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown AppleScript error"
            let code = error["NSAppleScriptErrorNumber"] as? Int ?? -1
            throw MailError.scriptFailed(message: message, code: code)
        }

        // Parse list result
        var items: [String] = []
        let count = result.numberOfItems
        if count > 0 {
            for i in 1...count {
                if let item = result.atIndex(i)?.stringValue {
                    items.append(item)
                }
            }
        }
        return items
    }

    // MARK: - Account Operations

    /// List all mail accounts
    func listAccounts() throws -> [[String: Any]] {
        let script = """
        tell application "Mail"
            set accountList to {}
            repeat with acc in accounts
                set accInfo to {|name|:name of acc, |id|:id of acc, |enabled|:enabled of acc, |type|:account type of acc as string}
                set end of accountList to accInfo
            end repeat
            return accountList
        end tell
        """

        // For simplicity, get names and basic info
        let namesScript = """
        tell application "Mail"
            get name of every account
        end tell
        """

        let names = try runScriptAsList(namesScript)

        return names.map { name in
            ["name": name]
        }
    }

    /// Get account details
    func getAccountInfo(accountName: String) throws -> [String: Any] {
        let script = """
        tell application "Mail"
            set acc to account "\(escapeForAppleScript(accountName))"
            return {|name|:name of acc, |enabled|:enabled of acc, |email|:email addresses of acc}
        end tell
        """

        let enabledScript = """
        tell application "Mail"
            get enabled of account "\(escapeForAppleScript(accountName))"
        end tell
        """

        let emailsScript = """
        tell application "Mail"
            get email addresses of account "\(escapeForAppleScript(accountName))"
        end tell
        """

        let enabled = try runScript(enabledScript)
        let emails = try runScriptAsList(emailsScript)

        return [
            "name": accountName,
            "enabled": enabled == "true",
            "email_addresses": emails
        ]
    }

    // MARK: - Mailbox Operations

    /// List mailboxes for an account
    func listMailboxes(accountName: String? = nil) throws -> [[String: Any]] {
        let script: String
        if let account = accountName {
            script = """
            tell application "Mail"
                set mbList to {}
                repeat with mb in mailboxes of account "\(escapeForAppleScript(account))"
                    set mbInfo to {|name|:name of mb, |unreadCount|:unread count of mb, |messageCount|:count of messages of mb}
                    set end of mbList to mbInfo
                end repeat
                return mbList
            end tell
            """
        } else {
            script = """
            tell application "Mail"
                set mbList to {}
                repeat with acc in accounts
                    repeat with mb in mailboxes of acc
                        set mbInfo to {|name|:name of mb, |account|:name of acc, |unreadCount|:unread count of mb}
                        set end of mbList to mbInfo
                    end repeat
                end repeat
                return mbList
            end tell
            """
        }

        // Simplified: get mailbox names
        let namesScript: String
        if let account = accountName {
            namesScript = """
            tell application "Mail"
                get name of every mailbox of account "\(escapeForAppleScript(account))"
            end tell
            """
        } else {
            namesScript = """
            tell application "Mail"
                set allNames to {}
                repeat with acc in accounts
                    set accMailboxes to name of every mailbox of acc
                    set allNames to allNames & accMailboxes
                end repeat
                return allNames
            end tell
            """
        }

        let names = try runScriptAsList(namesScript)

        return names.map { name in
            var info: [String: Any] = ["name": name]
            if let account = accountName {
                info["account"] = account
            }
            return info
        }
    }

    /// Create a new mailbox
    func createMailbox(name: String, accountName: String) throws -> String {
        let script = """
        tell application "Mail"
            make new mailbox with properties {name:"\(escapeForAppleScript(name))"} at account "\(escapeForAppleScript(accountName))"
            return "Created mailbox: \(escapeForAppleScript(name))"
        end tell
        """
        return try runScript(script)
    }

    /// Delete a mailbox
    func deleteMailbox(name: String, accountName: String) throws -> String {
        let script = """
        tell application "Mail"
            delete mailbox "\(escapeForAppleScript(name))" of account "\(escapeForAppleScript(accountName))"
            return "Deleted mailbox: \(escapeForAppleScript(name))"
        end tell
        """
        return try runScript(script)
    }

    // MARK: - Email Operations

    /// List emails in a mailbox
    func listEmails(mailbox: String, accountName: String, limit: Int = 50) throws -> [[String: Any]] {
        let script = """
        tell application "Mail"
            set msgs to messages 1 thru \(limit) of mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(accountName))"
            set msgList to {}
            repeat with msg in msgs
                set msgInfo to {|id|:id of msg, |subject|:subject of msg, |sender|:sender of msg, |dateReceived|:date received of msg as string, |read|:read status of msg}
                set end of msgList to msgInfo
            end repeat
            return msgList
        end tell
        """

        // Simplified approach: get basic info (clamp limit to actual message count)
        let subjectsScript = """
        tell application "Mail"
            set mb to mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(accountName))"
            set msgCount to count of messages of mb
            if msgCount = 0 then return {}
            if \(limit) < msgCount then
                set actualLimit to \(limit)
            else
                set actualLimit to msgCount
            end if
            get subject of messages 1 thru actualLimit of mb
        end tell
        """

        let sendersScript = """
        tell application "Mail"
            set mb to mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(accountName))"
            set msgCount to count of messages of mb
            if msgCount = 0 then return {}
            if \(limit) < msgCount then
                set actualLimit to \(limit)
            else
                set actualLimit to msgCount
            end if
            get sender of messages 1 thru actualLimit of mb
        end tell
        """

        let idsScript = """
        tell application "Mail"
            set mb to mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(accountName))"
            set msgCount to count of messages of mb
            if msgCount = 0 then return {}
            if \(limit) < msgCount then
                set actualLimit to \(limit)
            else
                set actualLimit to msgCount
            end if
            get id of messages 1 thru actualLimit of mb
        end tell
        """

        let subjects = try runScriptAsList(subjectsScript)
        let senders = try runScriptAsList(sendersScript)
        let ids = try runScriptAsList(idsScript)

        var emails: [[String: Any]] = []
        for i in 0..<min(subjects.count, senders.count, ids.count) {
            emails.append([
                "id": ids[i],
                "subject": subjects[i],
                "sender": senders[i]
            ])
        }

        return emails
    }

    /// Get email content by ID
    /// - format: "html" (default) returns HTML body with links preserved;
    ///           "text" returns plain text content;
    ///           "source" returns full MIME source
    func getEmail(id: String, mailbox: String, accountName: String, format: String = "html") throws -> [String: Any] {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)

        let subjectScript = """
        tell application "Mail"
            get subject of \(ref)
        end tell
        """

        let senderScript = """
        tell application "Mail"
            get sender of \(ref)
        end tell
        """

        let dateScript = """
        tell application "Mail"
            get date received of \(ref) as string
        end tell
        """

        let subject = try runScript(subjectScript)
        let sender = try runScript(senderScript)
        let dateReceived = try runScript(dateScript)

        let content: String
        switch format {
        case "text":
            let contentScript = """
            tell application "Mail"
                get content of \(ref)
            end tell
            """
            content = try runScript(contentScript)

        case "source":
            let sourceScript = """
            tell application "Mail"
                get source of \(ref)
            end tell
            """
            content = try runScript(sourceScript)

        default: // "html"
            let sourceScript = """
            tell application "Mail"
                get source of \(ref)
            end tell
            """
            let rawSource = try runScript(sourceScript)
            content = extractHTMLBody(from: rawSource)
        }

        return [
            "id": id,
            "subject": subject,
            "sender": sender,
            "date_received": dateReceived,
            "format": format,
            "content": content
        ]
    }

    /// Extract HTML body from MIME source, falling back to plain text content
    private func extractHTMLBody(from mimeSource: String) -> String {
        // Look for text/html part in multipart message
        // Find the HTML content between Content-Type: text/html and the next boundary
        let lines = mimeSource.components(separatedBy: "\n")
        var inHTMLPart = false
        var pastHTMLHeaders = false
        var htmlLines: [String] = []
        var boundary: String?

        // Find boundary from Content-Type header
        for line in lines {
            if line.contains("boundary=") {
                if let range = line.range(of: "boundary=\"") {
                    let start = range.upperBound
                    if let end = line[start...].firstIndex(of: "\"") {
                        boundary = String(line[start..<end])
                    }
                } else if let range = line.range(of: "boundary=") {
                    let start = range.upperBound
                    boundary = line[start...].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        for line in lines {
            if line.contains("Content-Type: text/html") {
                inHTMLPart = true
                pastHTMLHeaders = false
                continue
            }

            if inHTMLPart && !pastHTMLHeaders {
                // Skip headers until empty line
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pastHTMLHeaders = true
                }
                continue
            }

            if inHTMLPart && pastHTMLHeaders {
                // Check for boundary end
                if let b = boundary, line.contains(b) {
                    break
                }
                htmlLines.append(line)
            }
        }

        if htmlLines.isEmpty {
            return mimeSource // Fallback: return raw source if no HTML found
        }

        var html = htmlLines.joined(separator: "\n")

        // Decode quoted-printable encoding
        html = decodeQuotedPrintable(html)

        return html
    }

    /// Decode quoted-printable encoded string
    private func decodeQuotedPrintable(_ input: String) -> String {
        var result = input
        // Remove soft line breaks (= at end of line)
        result = result.replacingOccurrences(of: "=\r\n", with: "")
        result = result.replacingOccurrences(of: "=\n", with: "")

        // Decode =XX hex sequences
        var output = ""
        var i = result.startIndex
        while i < result.endIndex {
            if result[i] == "=" && result.distance(from: i, to: result.endIndex) >= 3 {
                let hexStart = result.index(after: i)
                let hexEnd = result.index(hexStart, offsetBy: 2)
                let hex = String(result[hexStart..<hexEnd])
                if let byte = UInt8(hex, radix: 16) {
                    output.append(Character(Unicode.Scalar(byte)))
                } else {
                    output.append(result[i])
                }
                i = hexEnd
            } else {
                output.append(result[i])
                i = result.index(after: i)
            }
        }

        return output
    }

    /// Search emails
    func searchEmails(query: String, mailbox: String? = nil, accountName: String? = nil, limit: Int = 20, sort: String = "desc") throws -> [[String: Any]] {
        let escapedQuery = escapeForAppleScript(query)
        let sep = "⏐"  // Separator unlikely to appear in email fields

        let script: String
        if let mailbox = mailbox, let accountName = accountName {
            // Search specific mailbox of specific account
            script = """
            tell application "Mail"
                set foundMsgs to (messages of mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(accountName))" whose subject contains "\(escapedQuery)" or sender contains "\(escapedQuery)")
                set results to {}
                set counter to 0
                repeat with msg in foundMsgs
                    if counter ≥ \(limit) then exit repeat
                    set end of results to (id of msg as string) & "\(sep)" & (subject of msg) & "\(sep)" & (sender of msg) & "\(sep)" & (date received of msg as string) & "\(sep)" & "\(escapeForAppleScript(accountName))" & "\(sep)" & "\(escapeForAppleScript(mailbox))"
                    set counter to counter + 1
                end repeat
                return results
            end tell
            """
        } else {
            // Search across all accounts and mailboxes
            script = """
            tell application "Mail"
                set results to {}
                set counter to 0
                repeat with acct in every account
                    if not (enabled of acct) then next
                    set acctName to name of acct
                    repeat with mbox in every mailbox of acct
                        try
                            set mboxName to name of mbox
                            set foundMsgs to (messages of mbox whose subject contains "\(escapedQuery)" or sender contains "\(escapedQuery)")
                            repeat with msg in foundMsgs
                                if counter ≥ \(limit) then exit repeat
                                set end of results to (id of msg as string) & "\(sep)" & (subject of msg) & "\(sep)" & (sender of msg) & "\(sep)" & (date received of msg as string) & "\(sep)" & acctName & "\(sep)" & mboxName
                                set counter to counter + 1
                            end repeat
                        end try
                        if counter ≥ \(limit) then exit repeat
                    end repeat
                    if counter ≥ \(limit) then exit repeat
                end repeat
                return results
            end tell
            """
        }

        let rows = try runScriptAsList(script)

        var emails: [[String: Any]] = []
        for row in rows {
            let fields = row.components(separatedBy: sep)
            guard fields.count >= 6 else { continue }
            emails.append([
                "id": fields[0],
                "subject": fields[1],
                "sender": fields[2],
                "date_received": fields[3],
                "account_name": fields[4],
                "mailbox": fields[5]
            ])
        }

        // Sort by date_received string (Apple Mail returns localized date strings)
        if sort == "asc" {
            emails.reverse()  // Apple Mail returns newest first, reverse for ascending
        }
        // "desc" (default) = newest first, which is Apple Mail's natural order

        return emails
    }

    /// Get unread count
    func getUnreadCount(mailbox: String? = nil, accountName: String? = nil) throws -> Int {
        let script: String
        if let mailbox = mailbox, let account = accountName {
            script = """
            tell application "Mail"
                get unread count of mailbox "\(escapeForAppleScript(mailbox))" of account "\(escapeForAppleScript(account))"
            end tell
            """
        } else if let account = accountName {
            script = """
            tell application "Mail"
                set total to 0
                repeat with mb in mailboxes of account "\(escapeForAppleScript(account))"
                    set total to total + (unread count of mb)
                end repeat
                return total
            end tell
            """
        } else {
            script = """
            tell application "Mail"
                set total to 0
                repeat with acc in accounts
                    repeat with mb in mailboxes of acc
                        set total to total + (unread count of mb)
                    end repeat
                end repeat
                return total
            end tell
            """
        }

        let result = try runScript(script)
        return Int(result) ?? 0
    }

    // MARK: - Email Actions

    /// Mark email as read/unread
    func markRead(id: String, mailbox: String, accountName: String, read: Bool) throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set read status of \(ref) to \(read)
            return "Email marked as \(read ? "read" : "unread")"
        end tell
        """
        return try runScript(script)
    }

    /// Flag email
    func flagEmail(id: String, mailbox: String, accountName: String, flagged: Bool) throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set flagged status of \(ref) to \(flagged)
            return "Email \(flagged ? "flagged" : "unflagged")"
        end tell
        """
        return try runScript(script)
    }

    /// Move email to another mailbox
    func moveEmail(id: String, fromMailbox: String, toMailbox: String, accountName: String) throws -> String {
        let ref = msgRef(id, mailbox: fromMailbox, account: accountName)
        let script = """
        tell application "Mail"
            set msg to \(ref)
            move msg to mailbox "\(escapeForAppleScript(toMailbox))" of account "\(escapeForAppleScript(accountName))"
            return "Email moved to \(escapeForAppleScript(toMailbox))"
        end tell
        """
        return try runScript(script)
    }

    /// Delete email (move to trash)
    func deleteEmail(id: String, mailbox: String, accountName: String) throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            delete \(ref)
            return "Email deleted"
        end tell
        """
        return try runScript(script)
    }

    // MARK: - Compose Operations

    /// Validate that all file paths exist, throwing with a clear message if any are missing
    private func validateFilePaths(_ paths: [String]) throws {
        let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
        guard missing.isEmpty else {
            throw MailError.invalidParameter("File(s) not found: \(missing.joined(separator: ", "))")
        }
    }

    /// Generate AppleScript lines to attach files to an outgoing message
    private func attachmentScript(for paths: [String]) -> String {
        paths.map { path in
            """
                make new attachment with properties {file name:POSIX file "\(escapeForAppleScript(path))"} at after the last paragraph
            """
        }.joined()
    }

    /// Compose and send a new email
    func composeEmail(to: [String], subject: String, body: String, cc: [String]? = nil, bcc: [String]? = nil, attachments: [String]? = nil, accountName: String? = nil) throws -> String {
        if let attachments = attachments { try validateFilePaths(attachments) }

        var script = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:"\(escapeForAppleScript(subject))", content:"\(escapeForAppleScript(body))", visible:true}
            tell newMessage
        """

        for recipient in to {
            script += """
                make new to recipient at end of to recipients with properties {address:"\(escapeForAppleScript(recipient))"}
            """
        }

        if let cc = cc {
            for recipient in cc {
                script += """
                    make new cc recipient at end of cc recipients with properties {address:"\(escapeForAppleScript(recipient))"}
                """
            }
        }

        if let bcc = bcc {
            for recipient in bcc {
                script += """
                    make new bcc recipient at end of bcc recipients with properties {address:"\(escapeForAppleScript(recipient))"}
                """
            }
        }

        if let attachments = attachments {
            script += attachmentScript(for: attachments)
        }

        script += """
            end tell
            send newMessage
            return "Email sent successfully"
        end tell
        """

        return try runScript(script)
    }

    /// Reply to an email
    func replyEmail(id: String, mailbox: String, accountName: String, body: String, replyAll: Bool = false) throws -> String {
        let replyType = replyAll ? "reply all" : "reply"
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set originalMsg to \(ref)
            set replyMsg to \(replyType) originalMsg with opening window
            tell replyMsg
                set content to "\(escapeForAppleScript(body))" & return & return & content
            end tell
            send replyMsg
            return "Reply sent successfully"
        end tell
        """
        return try runScript(script)
    }

    /// Forward an email
    func forwardEmail(id: String, mailbox: String, accountName: String, to: [String], body: String? = nil) throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        var script = """
        tell application "Mail"
            set originalMsg to \(ref)
            set fwdMsg to forward originalMsg with opening window
            tell fwdMsg
        """

        for recipient in to {
            script += """
                make new to recipient at end of to recipients with properties {address:"\(escapeForAppleScript(recipient))"}
            """
        }

        if let body = body {
            script += """
                set content to "\(escapeForAppleScript(body))" & return & return & content
            """
        }

        script += """
            end tell
            send fwdMsg
            return "Email forwarded successfully"
        end tell
        """

        return try runScript(script)
    }

    // MARK: - Draft Operations

    /// List drafts
    func listDrafts(accountName: String) throws -> [[String: Any]] {
        let script = """
        tell application "Mail"
            get subject of messages of mailbox "Drafts" of account "\(escapeForAppleScript(accountName))"
        end tell
        """

        let subjects = try runScriptAsList(script)

        return subjects.map { subject in
            ["subject": subject]
        }
    }

    /// Create a draft
    func createDraft(to: [String], subject: String, body: String, attachments: [String]? = nil, accountName: String? = nil) throws -> String {
        if let attachments = attachments { try validateFilePaths(attachments) }

        var script = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:"\(escapeForAppleScript(subject))", content:"\(escapeForAppleScript(body))", visible:true}
            tell newMessage
        """

        for recipient in to {
            script += """
                make new to recipient at end of to recipients with properties {address:"\(escapeForAppleScript(recipient))"}
            """
        }

        if let attachments = attachments {
            script += attachmentScript(for: attachments)
        }

        script += """
            end tell
            save newMessage
            return "Draft created successfully"
        end tell
        """

        return try runScript(script)
    }

    // MARK: - Attachment Operations

    /// List attachments of an email
    func listAttachments(id: String, mailbox: String, accountName: String) throws -> [[String: Any]] {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set msg to \(ref)
            set attachmentList to {}
            repeat with att in mail attachments of msg
                set attInfo to {|name|:name of att, |size|:file size of att}
                set end of attachmentList to attInfo
            end repeat
            return attachmentList
        end tell
        """

        let namesScript = """
        tell application "Mail"
            get name of every mail attachment of \(ref)
        end tell
        """

        let names = try runScriptAsList(namesScript)

        return names.map { name in
            ["name": name]
        }
    }

    /// Save attachment to disk
    func saveAttachment(id: String, mailbox: String, accountName: String, attachmentName: String, savePath: String) throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set msg to \(ref)
            repeat with att in mail attachments of msg
                if name of att is "\(escapeForAppleScript(attachmentName))" then
                    save att in POSIX file "\(escapeForAppleScript(savePath))"
                    return "Attachment saved to \(escapeForAppleScript(savePath))"
                end if
            end repeat
            return "Attachment not found"
        end tell
        """
        return try runScript(script)
    }

    // MARK: - VIP Operations

    /// List VIP senders
    func listVIPSenders() throws -> [String] {
        let script = """
        tell application "Mail"
            get sender of messages of mailbox "VIP"
        end tell
        """

        return try runScriptAsList(script)
    }

    // MARK: - Rule Operations

    /// List mail rules
    func listRules() throws -> [[String: Any]] {
        let script = """
        tell application "Mail"
            get name of every rule
        end tell
        """

        let names = try runScriptAsList(script)

        return names.map { name in
            ["name": name]
        }
    }

    /// Enable/disable a rule
    func enableRule(name: String, enabled: Bool) throws -> String {
        let script = """
        tell application "Mail"
            set enabled of rule "\(escapeForAppleScript(name))" to \(enabled)
            return "Rule '\(escapeForAppleScript(name))' \(enabled ? "enabled" : "disabled")"
        end tell
        """
        return try runScript(script)
    }

    /// Get detailed rule information
    func getRuleDetails(name: String) throws -> [String: Any] {
        let enabledScript = """
        tell application "Mail"
            get enabled of rule "\(escapeForAppleScript(name))"
        end tell
        """

        let allConditionsScript = """
        tell application "Mail"
            get all conditions must be met of rule "\(escapeForAppleScript(name))"
        end tell
        """

        let stopScript = """
        tell application "Mail"
            get stop evaluating rules of rule "\(escapeForAppleScript(name))"
        end tell
        """

        let enabled = try runScript(enabledScript) == "true"
        let allConditions = try runScript(allConditionsScript) == "true"
        let stopEvaluating = try runScript(stopScript) == "true"

        return [
            "name": name,
            "enabled": enabled,
            "all_conditions_must_be_met": allConditions,
            "stop_evaluating_rules": stopEvaluating
        ]
    }

    /// Create a simple mail rule
    func createRule(name: String, conditions: [[String: String]], actions: [String: Any]) throws -> String {
        var script = """
        tell application "Mail"
            set newRule to make new rule with properties {name:"\(escapeForAppleScript(name))"}
        """

        // Add conditions
        for condition in conditions {
            if let header = condition["header"],
               let qualifier = condition["qualifier"],
               let expression = condition["expression"] {
                script += """
                    tell newRule
                        make new rule condition with properties {rule type:header rule, header:"\(escapeForAppleScript(header))", qualifier:\(qualifier), expression:"\(escapeForAppleScript(expression))"}
                    end tell
                """
            }
        }

        // Add actions
        if let moveMailbox = actions["move_message"] as? String {
            script += """
                set move message of newRule to mailbox "\(escapeForAppleScript(moveMailbox))"
            """
        }

        if let markRead = actions["mark_read"] as? Bool {
            script += """
                set mark read of newRule to \(markRead)
            """
        }

        if let markFlagged = actions["mark_flagged"] as? Bool {
            script += """
                set mark flagged of newRule to \(markFlagged)
            """
        }

        if let deleteMessage = actions["delete_message"] as? Bool {
            script += """
                set delete message of newRule to \(deleteMessage)
            """
        }

        script += """
            return "Rule '\(escapeForAppleScript(name))' created successfully"
        end tell
        """

        return try runScript(script)
    }

    /// Delete a rule
    func deleteRule(name: String) throws -> String {
        let script = """
        tell application "Mail"
            delete rule "\(escapeForAppleScript(name))"
            return "Rule '\(escapeForAppleScript(name))' deleted"
        end tell
        """
        return try runScript(script)
    }

    // MARK: - Mail Check & Sync Operations

    /// Check for new mail
    func checkForNewMail(accountName: String? = nil) throws -> String {
        let script: String
        if let account = accountName {
            script = """
            tell application "Mail"
                check for new mail for account "\(escapeForAppleScript(account))"
                return "Checking for new mail in \(escapeForAppleScript(account))"
            end tell
            """
        } else {
            script = """
            tell application "Mail"
                check for new mail
                return "Checking for new mail in all accounts"
            end tell
            """
        }
        return try runScript(script)
    }

    /// Synchronize IMAP account
    func synchronizeAccount(accountName: String) throws -> String {
        let script = """
        tell application "Mail"
            synchronize account "\(escapeForAppleScript(accountName))"
            return "Synchronizing account: \(escapeForAppleScript(accountName))"
        end tell
        """
        return try runScript(script)
    }

    // MARK: - Advanced Email Operations

    /// Copy email to another mailbox
    func copyEmail(id: String, fromMailbox: String, toMailbox: String, accountName: String) throws -> String {
        let ref = msgRef(id, mailbox: fromMailbox, account: accountName)
        let script = """
        tell application "Mail"
            set msg to \(ref)
            duplicate msg to mailbox "\(escapeForAppleScript(toMailbox))" of account "\(escapeForAppleScript(accountName))"
            return "Email copied to \(escapeForAppleScript(toMailbox))"
        end tell
        """
        return try runScript(script)
    }

    /// Set flag color (0-6: red, orange, yellow, green, blue, purple, gray; -1 to clear)
    func setFlagColor(id: String, mailbox: String, accountName: String, colorIndex: Int) throws -> String {
        let colors = ["red", "orange", "yellow", "green", "blue", "purple", "gray"]
        let colorName = colorIndex >= 0 && colorIndex < colors.count ? colors[colorIndex] : "none"

        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set flag index of \(ref) to \(colorIndex)
            return "Flag color set to \(colorName)"
        end tell
        """
        return try runScript(script)
    }

    /// Set email background color
    func setBackgroundColor(id: String, mailbox: String, accountName: String, color: String) throws -> String {
        // Valid colors: blue, gray, green, none, orange, purple, red, yellow
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set background color of \(ref) to \(color)
            return "Background color set to \(color)"
        end tell
        """
        return try runScript(script)
    }

    /// Mark email as junk or not junk
    func markAsJunk(id: String, mailbox: String, accountName: String, isJunk: Bool) throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set junk mail status of \(ref) to \(isJunk)
            return "Email marked as \(isJunk ? "junk" : "not junk")"
        end tell
        """
        return try runScript(script)
    }

    /// Get all email headers
    func getEmailHeaders(id: String, mailbox: String, accountName: String) throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            get all headers of \(ref)
        end tell
        """
        return try runScript(script)
    }

    /// Get email source (raw message)
    func getEmailSource(id: String, mailbox: String, accountName: String) throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            get source of \(ref)
        end tell
        """
        return try runScript(script)
    }

    /// Redirect email (different from forward - keeps original sender)
    func redirectEmail(id: String, mailbox: String, accountName: String, to: [String]) throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        var script = """
        tell application "Mail"
            set originalMsg to \(ref)
            set redirectMsg to redirect originalMsg with opening window
            tell redirectMsg
        """

        for recipient in to {
            script += """
                make new to recipient at end of to recipients with properties {address:"\(escapeForAppleScript(recipient))"}
            """
        }

        script += """
            end tell
            send redirectMsg
            return "Email redirected successfully"
        end tell
        """

        return try runScript(script)
    }

    /// Get email metadata (was forwarded, replied to, redirected)
    func getEmailMetadata(id: String, mailbox: String, accountName: String) throws -> [String: Any] {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)

        let forwardedScript = """
        tell application "Mail"
            get was forwarded of \(ref)
        end tell
        """

        let repliedScript = """
        tell application "Mail"
            get was replied to of \(ref)
        end tell
        """

        let redirectedScript = """
        tell application "Mail"
            get was redirected of \(ref)
        end tell
        """

        let messageIdScript = """
        tell application "Mail"
            get message id of \(ref)
        end tell
        """

        let sizeScript = """
        tell application "Mail"
            get message size of \(ref)
        end tell
        """

        let wasForwarded = try runScript(forwardedScript) == "true"
        let wasReplied = try runScript(repliedScript) == "true"
        let wasRedirected = try runScript(redirectedScript) == "true"
        let msgId = try runScript(messageIdScript)
        let size = try runScript(sizeScript)

        return [
            "was_forwarded": wasForwarded,
            "was_replied_to": wasReplied,
            "was_redirected": wasRedirected,
            "message_id": msgId,
            "size_bytes": Int(size) ?? 0
        ]
    }

    // MARK: - Signature Operations

    /// List all signatures
    func listSignatures() throws -> [[String: Any]] {
        // First check if there are any signatures
        let countScript = """
        tell application "Mail"
            get count of signatures
        end tell
        """

        let countResult = try runScript(countScript)
        guard let count = Int(countResult), count > 0 else {
            return []
        }

        let namesScript = """
        tell application "Mail"
            get name of every signature
        end tell
        """

        let names = try runScriptAsList(namesScript)

        return names.map { name in
            ["name": name]
        }
    }

    /// Get signature content
    func getSignature(name: String) throws -> [String: Any] {
        let contentScript = """
        tell application "Mail"
            get content of signature "\(escapeForAppleScript(name))"
        end tell
        """

        let content = try runScript(contentScript)

        return [
            "name": name,
            "content": content
        ]
    }

    // MARK: - SMTP Server Operations

    /// List SMTP servers
    func listSMTPServers() throws -> [[String: Any]] {
        let namesScript = """
        tell application "Mail"
            get name of every smtp server
        end tell
        """

        let serverNamesScript = """
        tell application "Mail"
            get server name of every smtp server
        end tell
        """

        let names = try runScriptAsList(namesScript)
        let serverNames = try runScriptAsList(serverNamesScript)

        var servers: [[String: Any]] = []
        for i in 0..<names.count {
            var server: [String: Any] = ["name": names[i]]
            if i < serverNames.count {
                server["server_name"] = serverNames[i]
            }
            servers.append(server)
        }

        return servers
    }

    // MARK: - Special Mailboxes

    /// Get special mailboxes (inbox, drafts, sent, trash, junk, outbox)
    func getSpecialMailboxes() throws -> [String: Any] {
        let inboxScript = """
        tell application "Mail"
            get name of inbox
        end tell
        """

        let draftsScript = """
        tell application "Mail"
            get name of drafts mailbox
        end tell
        """

        let sentScript = """
        tell application "Mail"
            get name of sent mailbox
        end tell
        """

        let trashScript = """
        tell application "Mail"
            get name of trash mailbox
        end tell
        """

        let junkScript = """
        tell application "Mail"
            get name of junk mailbox
        end tell
        """

        let outboxScript = """
        tell application "Mail"
            get name of outbox
        end tell
        """

        return [
            "inbox": try runScript(inboxScript),
            "drafts": try runScript(draftsScript),
            "sent": try runScript(sentScript),
            "trash": try runScript(trashScript),
            "junk": try runScript(junkScript),
            "outbox": try runScript(outboxScript)
        ]
    }

    // MARK: - Address Operations

    /// Extract name from email address
    func extractNameFromAddress(address: String) throws -> String {
        let script = """
        tell application "Mail"
            extract name from "\(escapeForAppleScript(address))"
        end tell
        """
        return try runScript(script)
    }

    /// Extract email address from full address string
    func extractAddressFrom(address: String) throws -> String {
        let script = """
        tell application "Mail"
            extract address from "\(escapeForAppleScript(address))"
        end tell
        """
        return try runScript(script)
    }

    // MARK: - Application Operations

    /// Get Mail application info
    func getMailAppInfo() throws -> [String: Any] {
        let versionScript = """
        tell application "Mail"
            get application version
        end tell
        """

        let fetchIntervalScript = """
        tell application "Mail"
            get fetch interval
        end tell
        """

        let backgroundCountScript = """
        tell application "Mail"
            get background activity count
        end tell
        """

        let version = try runScript(versionScript)
        let fetchInterval = try runScript(fetchIntervalScript)
        let bgCount = try runScript(backgroundCountScript)

        return [
            "version": version,
            "fetch_interval_minutes": Int(fetchInterval) ?? -1,
            "background_activity_count": Int(bgCount) ?? 0
        ]
    }

    /// Open mailto URL
    func openMailtoURL(url: String) throws -> String {
        let script = """
        tell application "Mail"
            mailto "\(escapeForAppleScript(url))"
            return "Opened mailto URL"
        end tell
        """
        return try runScript(script)
    }

    // MARK: - Import/Export Operations

    /// Import mailbox from file
    func importMailbox(path: String) throws -> String {
        let script = """
        tell application "Mail"
            import Mail mailbox POSIX file "\(escapeForAppleScript(path))"
            return "Mailbox imported from \(escapeForAppleScript(path))"
        end tell
        """
        return try runScript(script)
    }

    // MARK: - Helpers

    /// Generate AppleScript reference to find a message by its numeric id.
    /// Apple Mail's `message id` refers to the RFC822 Message-ID (string),
    /// but `id` is the internal numeric identifier returned by search/list.
    /// We must use `first message ... whose id is N` instead of `message id N`.
    private func msgRef(_ id: String, mailbox: String, account: String) -> String {
        return "(first message of mailbox \"\(escapeForAppleScript(mailbox))\" of account \"\(escapeForAppleScript(account))\" whose id is \(id))"
    }

    /// Escape special characters for AppleScript strings.
    /// AppleScript does not support C-style escape sequences (\n, \t).
    /// Newlines must be expressed as: `" & return & "` string concatenation.
    private func escapeForAppleScript(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\" & return & \"")
            .replacingOccurrences(of: "\n", with: "\" & return & \"")
            .replacingOccurrences(of: "\r", with: "\" & return & \"")
            .replacingOccurrences(of: "\t", with: "\" & tab & \"")
    }
}

// MARK: - Mail Error

enum MailError: LocalizedError {
    case scriptCreationFailed
    case scriptFailed(message: String, code: Int)
    case invalidParameter(String)

    var errorDescription: String? {
        switch self {
        case .scriptCreationFailed:
            return "Failed to create AppleScript"
        case .scriptFailed(let message, let code):
            return "AppleScript error (\(code)): \(message)"
        case .invalidParameter(let message):
            return "Invalid parameter: \(message)"
        }
    }
}
