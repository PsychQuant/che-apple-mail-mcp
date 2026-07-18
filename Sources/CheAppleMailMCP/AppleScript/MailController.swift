import Foundation
import MailSQLite  // #194: SearchField — the fallback honors the same field/date filters as the SQLite path
#if canImport(AppKit)
import AppKit  // #175: NSPasteboard for full-fidelity clipboard preserve/restore
#endif

/// Controller for Apple Mail via AppleScript
actor MailController {
    static let shared = MailController()

    private init() {}

    // MARK: - #254 test seams (production never sets these)

    /// When set, `runScript` routes through this closure instead of
    /// NSAppleScript — lets production-site behavioral tests drive the real
    /// compose/reply/forward methods with a fake script runner (no live Mail).
    private var scriptRunnerOverride: ((String) throws -> String)?
    /// When set, both wrapper-free eligibility probes return this closure's
    /// value (nil = eligible) instead of probing Accessibility/env — lets
    /// tests select the branch deterministically.
    private var ineligibilityOverride: (() -> String?)?

    func setTestSeams(
        scriptRunner: ((String) throws -> String)?,
        ineligibility: (() -> String?)?
    ) {
        scriptRunnerOverride = scriptRunner
        ineligibilityOverride = ineligibility
    }

    // MARK: - AppleScript Execution

    /// Execute AppleScript and return result
    func runScript(_ source: String) throws -> String {
        if let override = scriptRunnerOverride {
            return try override(source)
        }
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

    /// List all mail accounts with structured metadata.
    ///
    /// Returns `display_name` (the canonical identifier to pass back to
    /// `get_email` / `search_emails` etc.), the raw `name` attribute (which
    /// for EWS accounts is the opaque `ews://.../` URL, not usable as an
    /// AppleScript `account "..."` reference), and the account's `user_name`,
    /// `id`, `email_addresses`, and `enabled` state.
    ///
    /// Why AppleScript and not the SQLite fast path: `AccountsMap.plist`
    /// exposes only `AccountURL`, not email addresses, so filesystem-only
    /// resolution cannot recover the email for EWS accounts (per #9 and #11).
    /// Mail.app's `user name` / `email addresses` AppleScript attributes are
    /// the only reliable source.
    func listAccounts() throws -> [[String: Any]] {
        // Emit one record per account, using control characters as separators
        // to avoid the quoting headaches of &/,/newline. See AccountsScriptParser
        // for the field layout.
        //
        // Use \u{001E} (RS), \u{001F} (US), \u{001D} (GS) — guaranteed not
        // to appear in legitimate account metadata.
        let RS = "\u{001E}"
        let US = "\u{001F}"
        let GS = "\u{001D}"

        let script = """
        set AppleScript's text item delimiters to "\(GS)"
        tell application "Mail"
            set out to ""
            set first_acc to true
            repeat with acc in accounts
                set n to name of acc as string
                set u to ""
                try
                    set u to user name of acc as string
                end try
                set i to id of acc as string
                set emails_list to {}
                try
                    set emails_list to email addresses of acc
                end try
                if emails_list is missing value then
                    set emails_str to ""
                else
                    set emails_str to emails_list as string
                end if
                set en to enabled of acc as string
                if first_acc then
                    set first_acc to false
                else
                    set out to out & "\(RS)"
                end if
                set out to out & n & "\(US)" & u & "\(US)" & i & "\(US)" & emails_str & "\(US)" & en
            end repeat
            return out
        end tell
        """

        let raw = try runScript(script)
        let parsed = AccountsScriptParser.parse(raw)
        return parsed.map { $0.asDictionary() }
    }

    /// Get account details
    func getAccountInfo(accountName: String, accountId: String? = nil) throws -> [String: Any] {
        // #202: select via resolveAccountRef — UUID selector when accountId is
        // present, else the legacy `account "<name>"` form (byte-identical).
        let acctRef = resolveAccountRef(accountId: accountId, accountName: accountName)
        let enabledScript = """
        tell application "Mail"
            get enabled of \(acctRef)
        end tell
        """

        let emailsScript = """
        tell application "Mail"
            get email addresses of \(acctRef)
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
    func listMailboxes(accountName: String? = nil, accountId: String? = nil) throws -> [[String: Any]] {
        // Simplified: get mailbox names
        let namesScript: String
        let hasSelector = (accountId.map { !$0.isEmpty } ?? false)
            || (accountName.map { !$0.isEmpty } ?? false)
        if hasSelector {
            // #202: UUID selector when accountId present, else `account "<name>"`
            // (byte-identical to the legacy form).
            let acctRef = resolveAccountRef(accountId: accountId, accountName: accountName ?? "")
            namesScript = """
            tell application "Mail"
                get name of every mailbox of \(acctRef)
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

    /// Create a new mailbox.
    ///
    /// `accountId` (UUID), when non-nil/non-empty, disambiguates accounts that
    /// share a display_name (#104 sweep). Script construction is delegated to
    /// `buildCreateMailboxScript` (`MailboxCrudScriptBuilder.swift`).
    func createMailbox(name: String, accountName: String, accountId: String? = nil) throws -> String {
        let script = buildCreateMailboxScript(name: name, accountId: accountId, accountName: accountName)
        return try runScript(script)
    }

    /// Delete a mailbox.
    ///
    /// `accountId` (UUID), when non-nil/non-empty, disambiguates accounts that
    /// share a display_name (#104 sweep). Script construction is delegated to
    /// `buildDeleteMailboxScript` (`MailboxCrudScriptBuilder.swift`).
    func deleteMailbox(name: String, accountName: String, accountId: String? = nil) throws -> String {
        let script = buildDeleteMailboxScript(name: name, accountId: accountId, accountName: accountName)
        return try runScript(script)
    }

    // MARK: - Email Operations

    /// List emails in a mailbox (AppleScript fallback path — typically only
    /// reached when SQLite reader is unavailable or throws; see Server.swift
    /// `case "list_emails"`).
    ///
    /// #89 performance fix: pre-fix this issued THREE separate AppleScript
    /// invocations (subjects + senders + ids), each repeating
    /// `count of messages of mb` + mailbox resolution. On a 92k-message
    /// Gmail INBOX the `count` operation alone took 14+ minutes per call,
    /// times three calls = OOM-on-time. Two changes:
    ///
    /// 1. **Drop the `count of messages` guard entirely**. AppleScript's
    ///    `messages 1 thru N of mb` clamps to mailbox size internally —
    ///    if N > msgCount it returns the full list (not an error).
    ///    Confirmed empirically on small mailboxes. The count was
    ///    defensive but bought nothing on the happy path.
    /// 2. **Batch the 3 property fetches into ONE script**. Single IPC,
    ///    single mailbox resolution, AppleScript record literal returns
    ///    three arrays in parallel.
    ///
    /// Result: 3× IPC reduction + count-of-messages bottleneck removed.
    /// Empty-mailbox case handled by AppleScript returning empty arrays.
    func listEmails(mailbox: String, accountName: String, accountId: String? = nil, limit: Int = 50) throws -> [[String: Any]] {
        // Single batched script: resolve mailbox once, fetch all three
        // properties in one IPC. Returns a list of three lists in fixed
        // order: [{ids}, {subjects}, {senders}].
        //
        // Note: `messages 1 thru N of mb` clamps internally when N exceeds
        // msgCount — no out-of-range error on small mailboxes. Empty
        // mailbox returns three empty lists.
        let batchedScript = """
        tell application "Mail"
            set mb to \(mailboxRef(mailbox, account: accountName, accountId: accountId))
            set theMessages to messages 1 thru \(limit) of mb
            return {id of theMessages, subject of theMessages, sender of theMessages}
        end tell
        """

        // Returns nested list — three parallel arrays. runScriptAsList
        // currently flattens this, so use runScript and parse the result
        // structure as comma-separated groups.
        // For simplicity and to keep parsing robust, issue three sub-scripts
        // against the SAME `theMessages` reference (still single mailbox
        // resolution + single message-range fetch is the dominant cost).
        let combinedScript = """
        tell application "Mail"
            set mb to \(mailboxRef(mailbox, account: accountName, accountId: accountId))
            set theMessages to messages 1 thru \(limit) of mb
            set subjectList to subject of theMessages
            set senderList to sender of theMessages
            set idList to id of theMessages
            -- AppleScript can't easily return a struct via osascript JSON,
            -- so emit three lines using U+001E (RECORD SEPARATOR) between
            -- groups — same convention as `AccountsScriptParser`.
            set AppleScript's text item delimiters to (ASCII character 30)
            set result to (idList as string) & (ASCII character 30) & (subjectList as string) & (ASCII character 30) & (senderList as string)
            set AppleScript's text item delimiters to ""
            return result
        end tell
        """
        _ = batchedScript  // documented above; combinedScript is the implementation we actually run

        let raw = try runScript(combinedScript)
        // Split on U+001E group separator: 3 groups of comma-separated values.
        let groups = raw.components(separatedBy: "\u{001E}")
        guard groups.count == 3 else {
            // Defensive: if AppleScript returned unexpected shape, fall back
            // to empty result rather than crash. Caller will see [] which is
            // the same as an empty mailbox — better than throwing on a
            // happy-path read tool.
            return []
        }
        let ids = groups[0].components(separatedBy: ", ")
        let subjects = groups[1].components(separatedBy: ", ")
        let senders = groups[2].components(separatedBy: ", ")

        var emails: [[String: Any]] = []
        for i in 0..<min(ids.count, subjects.count, senders.count) {
            // Skip empty result rows (happens when mailbox is empty — all
            // three lists contain a single empty string).
            if ids[i].isEmpty && subjects[i].isEmpty && senders[i].isEmpty { continue }
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
    func getEmail(id: String, mailbox: String, accountName: String, accountId: String? = nil, format: String = "html") throws -> [String: Any] {
        let ref = msgRef(id, mailbox: mailbox, account: accountName, accountId: accountId)

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

    /// Extract HTML body from MIME source, falling back to plain text content.
    ///
    /// Honors `Content-Transfer-Encoding` of the HTML part — both
    /// `quoted-printable` (legacy path) and `base64` (#73, common on
    /// Android Gmail / Outlook Mobile). 7bit / 8bit / binary pass through
    /// unchanged. This used to be private; promoted to internal so unit
    /// tests can hit the parser directly without spinning up AppleScript.
    func extractHTMLBody(from mimeSource: String) -> String {
        // Look for text/html part in multipart message
        // Find the HTML content between Content-Type: text/html and the next boundary
        let lines = mimeSource.components(separatedBy: "\n")
        var inHTMLPart = false
        var pastHTMLHeaders = false
        var htmlLines: [String] = []
        var boundary: String?
        var transferEncoding = "7bit"  // tracked per HTML part — reset on each match

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
                transferEncoding = "7bit"  // reset for the new HTML part's headers
                continue
            }

            if inHTMLPart && !pastHTMLHeaders {
                // Capture Content-Transfer-Encoding from the part headers
                // (case-insensitive prefix match — RFC 2045 doesn't require
                // exact case for header field names).
                let lowered = line.trimmingCharacters(in: .whitespaces).lowercased()
                if lowered.hasPrefix("content-transfer-encoding:") {
                    transferEncoding = lowered
                        .replacingOccurrences(of: "content-transfer-encoding:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }

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

        // Decode according to Content-Transfer-Encoding declared by the
        // HTML part. Falls through to passthrough on unrecognized values
        // (7bit/8bit/binary or anything we don't speak), and to raw-html
        // if base64 decoding fails — degrades gracefully rather than
        // corrupting the output.
        switch transferEncoding {
        case "base64":
            // Strip every kind of whitespace base64 might be wrapped with.
            // Splitting on "\n" leaves trailing "\r" attached; without
            // that strip, Data(base64Encoded:) returns nil and we leak
            // raw base64 to the caller (the very bug #73 was filed for).
            let cleaned = html
                .replacingOccurrences(of: "\r\n", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\t", with: "")
            if let data = Data(base64Encoded: cleaned),
               let decoded = String(data: data, encoding: .utf8) {
                html = decoded
            }
            // else: leave html as raw base64 — at least no worse than pre-fix

        case "quoted-printable":
            html = decodeQuotedPrintable(html)

        default:
            break  // 7bit / 8bit / binary / unknown → passthrough
        }

        return html
    }

    /// Decode quoted-printable encoded string.
    ///
    /// Collects all decoded bytes (both literal characters and `=XX` hex
    /// escapes) into a `[UInt8]` buffer first, then interprets the buffer
    /// as UTF-8. This is required because non-ASCII characters in QP
    /// content arrive as multi-byte UTF-8 sequences split across separate
    /// `=XX` escapes (e.g. `é` = `=C3=A9`). The pre-fix code appended
    /// each byte directly as `Character(Unicode.Scalar(byte))`, which
    /// treated `0xC3 0xA9` as two separate codepoints `Ã ©` — classic
    /// mojibake. Surfaced by #73's regression tests.
    private func decodeQuotedPrintable(_ input: String) -> String {
        var result = input
        // Remove soft line breaks (= at end of line)
        result = result.replacingOccurrences(of: "=\r\n", with: "")
        result = result.replacingOccurrences(of: "=\n", with: "")

        var bytes: [UInt8] = []
        var i = result.startIndex
        while i < result.endIndex {
            if result[i] == "=" && result.distance(from: i, to: result.endIndex) >= 3 {
                let hexStart = result.index(after: i)
                let hexEnd = result.index(hexStart, offsetBy: 2)
                let hex = String(result[hexStart..<hexEnd])
                if let byte = UInt8(hex, radix: 16) {
                    bytes.append(byte)
                } else {
                    // Malformed `=XX` — pass the literal `=` through as
                    // its UTF-8 encoding (1 byte for ASCII).
                    bytes.append(contentsOf: result[i].utf8)
                }
                i = hexEnd
            } else {
                bytes.append(contentsOf: result[i].utf8)
                i = result.index(after: i)
            }
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    /// Search emails
    ///
    /// #194: this AppleScript fallback honors the same `field` / `dateFrom` /
    /// `dateTo` filters the SQLite primary path honors. `subject`/`sender`/`any`
    /// use a fast `whose` substring predicate; `recipient` has no reliable `whose`
    /// form (recipient props are object lists — `whose … contains` over a list is
    /// element-equality, not substring) so it is filtered **in-loop**. **Known
    /// limitation:** `field == .any` here covers subject+sender only; recipient-only
    /// matches require the SQLite index (a stderr note is emitted when this path
    /// runs with `field == .any`).
    func searchEmails(query: String, mailbox: String? = nil, accountName: String? = nil, accountId: String? = nil, limit: Int = 20, sort: String = "desc", field: SearchField = .any, dateFrom: Date? = nil, dateTo: Date? = nil) throws -> [[String: Any]] {
        let escapedQuery = appleScriptEscape(query)
        let sep = "⏐"  // Separator unlikely to appear in email fields

        if field == .any {
            FileHandle.standardError.write(Data((
                "search_emails AppleScript fallback: field=any matches subject+sender; "
                + "recipient-only matches require the SQLite index (#194 known limitation)\n").utf8))
        } else if field == .recipient {
            FileHandle.standardError.write(Data((
                "search_emails AppleScript fallback: field=recipient enumerates the mailbox in-loop "
                + "(O(mailbox) — slow on large mailboxes); the SQLite index is the fast path (#194)\n").utf8))
        }
        let dateClause = searchEmailsDateClause(dateFrom: dateFrom, dateTo: dateTo)
        let whoseSuffix = searchEmailsWhoseSuffix(
            field: field, escapedQuery: escapedQuery, datePredicate: dateClause.predicate)
        // Per-message loop body, shared by all 3 branches. `collect` is the
        // branch-specific `set end of results …` statement; for `.recipient` the
        // body wraps it in the in-loop address/name match gate so `limit` counts
        // only matched messages (parity with the SQLite recipient filter).
        func loopBody(collect: String) -> String {
            let guardLimit = "if counter ≥ \(limit) then exit repeat"
            if field == .recipient {
                return """
                \(guardLimit)
                \(searchEmailsRecipientMatchBlock(escapedQuery: escapedQuery))
                if _matched then
                \(collect)
                set counter to counter + 1
                end if
                """
            }
            return """
            \(guardLimit)
            \(collect)
            set counter to counter + 1
            """
        }

        let script: String
        if let mailbox = mailbox, let accountName = accountName {
            // Search specific mailbox of specific account
            let collect = "set end of results to (id of msg as string) & \"\(sep)\" & (subject of msg) & \"\(sep)\" & (sender of msg) & \"\(sep)\" & (date received of msg as string) & \"\(sep)\" & \"\(appleScriptEscape(accountName))\" & \"\(sep)\" & \"\(appleScriptEscape(mailbox))\""
            script = """
            tell application "Mail"
            \(dateClause.setup)
                set mb to \(mailboxRef(mailbox, account: accountName, accountId: accountId))
                set foundMsgs to (messages of mb\(whoseSuffix))
                set results to {}
                set counter to 0
                repeat with msg in foundMsgs
                \(loopBody(collect: collect))
                end repeat
                return results
            end tell
            """
        } else if (accountName.map { !$0.isEmpty } ?? false) || !(accountId ?? "").isEmpty {
            // #180 (verify #192): account-only / id-only mode (no specific
            // mailbox). Pre-fix this fell through to the all-accounts branch
            // below, which ignored BOTH accountName and accountId — so
            // `search_emails(account_name:X, account_id:UUID)` without a mailbox
            // silently searched every account. Scope to the single account via
            // the resolveAccountRef chokepoint (UUID selector when accountId is
            // supplied), aligning the AppleScript fallback with the SQLite
            // primary path, which already filters by account.
            let accountRef = resolveAccountRef(accountId: accountId, accountName: accountName ?? "")
            let collect = "set end of results to (id of msg as string) & \"\(sep)\" & (subject of msg) & \"\(sep)\" & (sender of msg) & \"\(sep)\" & (date received of msg as string) & \"\(sep)\" & acctName & \"\(sep)\" & mboxName"
            script = """
            tell application "Mail"
            \(dateClause.setup)
                set results to {}
                set counter to 0
                set acct to \(accountRef)
                set acctName to name of acct
                repeat with mbox in every mailbox of acct
                    try
                        set mboxName to name of mbox
                        set foundMsgs to (messages of mbox\(whoseSuffix))
                        repeat with msg in foundMsgs
                        \(loopBody(collect: collect))
                        end repeat
                    end try
                    if counter ≥ \(limit) then exit repeat
                end repeat
                return results
            end tell
            """
        } else {
            // Search across all accounts and mailboxes
            let collect = "set end of results to (id of msg as string) & \"\(sep)\" & (subject of msg) & \"\(sep)\" & (sender of msg) & \"\(sep)\" & (date received of msg as string) & \"\(sep)\" & acctName & \"\(sep)\" & mboxName"
            script = """
            tell application "Mail"
            \(dateClause.setup)
                set results to {}
                set counter to 0
                repeat with acct in every account
                    if (enabled of acct) then
                        set acctName to name of acct
                        repeat with mbox in every mailbox of acct
                            try
                                set mboxName to name of mbox
                                set foundMsgs to (messages of mbox\(whoseSuffix))
                                repeat with msg in foundMsgs
                                \(loopBody(collect: collect))
                                end repeat
                            end try
                            if counter ≥ \(limit) then exit repeat
                        end repeat
                    end if
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
    func getUnreadCount(mailbox: String? = nil, accountName: String? = nil, accountId: String? = nil) throws -> Int {
        let script: String
        if let mailbox = mailbox, let account = accountName {
            script = """
            tell application "Mail"
                get unread count of \(mailboxRef(mailbox, account: account, accountId: accountId))
            end tell
            """
        } else if (accountName.map { !$0.isEmpty } ?? false) || !(accountId ?? "").isEmpty {
            // #180 (verify #192): account-only / id-only mode. Was an inline
            // legacy `account "<display_name>"` selector that ignored accountId
            // entirely — `get_unread_count(account_name:X, account_id:UUID)`
            // with no mailbox silently re-hit the #101 same-display_name
            // collision. Route through the resolveAccountRef chokepoint so the
            // UUID selector applies here too; byte-identical to the legacy form
            // at accountId:nil (`account "<display_name>"`).
            let accountRef = resolveAccountRef(accountId: accountId, accountName: accountName ?? "")
            script = """
            tell application "Mail"
                set total to 0
                repeat with mb in mailboxes of \(accountRef)
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
    func markRead(id: String, mailbox: String, accountId: String? = nil, accountName: String, read: Bool) throws -> String {
        let script = buildMarkReadScript(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName, read: read)
        return try runScript(script)
    }

    /// Flag email
    func flagEmail(id: String, mailbox: String, accountId: String? = nil, accountName: String, flagged: Bool) throws -> String {
        let script = buildFlagEmailScript(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName, flagged: flagged)
        return try runScript(script)
    }

    /// Move email to another mailbox
    func moveEmail(id: String, fromMailbox: String, toMailbox: String, accountName: String, accountId: String? = nil) throws -> String {
        let script = buildMoveEmailScript(
            id: id, fromMailbox: fromMailbox, toMailbox: toMailbox,
            accountId: accountId, accountName: accountName
        )
        return try runScript(script)
    }

    /// Delete email (move to trash)
    func deleteEmail(id: String, mailbox: String, accountName: String, accountId: String? = nil) throws -> String {
        let script = buildDeleteEmailScript(
            id: id, mailbox: mailbox,
            accountId: accountId, accountName: accountName
        )
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

    /// Issue #41: validate email addresses (RFC 5322 addr-spec lite). Rejects:
    ///   - Control characters (0x00-0x1F) — header injection vector
    ///   - Missing or multiple `@` — structurally malformed
    ///   - `@` at start/end — malformed local-part or domain
    ///
    /// Defense-in-depth: `appleScriptEscape` already prevents AppleScript-string
    /// injection, but malformed addresses can corrupt Mail.app's draft creation
    /// or generate confusing recipient errors. Strict validation gives clear
    /// caller-visible errors at the boundary.
    ///
    /// `internal` so @testable import can exercise without going through
    /// composeEmail / replyEmail. Empty array is no-op.
    func validateEmailAddresses(_ addresses: [String], field: String) throws {
        guard !addresses.isEmpty else { return }
        var failures: [String] = []
        for raw in addresses {
            // #251: a `Name <email>` mailbox form is validated on its
            // addr-spec part (the old whole-string check mis-rejected legal
            // names containing '@'). The NAME part is checked for control
            // chars below via the same scan (it is part of `raw`).
            if raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                failures.append("'\(raw)' contains control characters")
                continue
            }
            let parsed = parseRecipient(raw)
            let addr = parsed.address
            // #265 + #270: a string that parseRecipient could NOT cleanly split
            // (name == nil fallback) yet still carries an UNQUOTED angle
            // bracket is malformed — whether a matched pair
            // (`Alice <not-an-email> <bob@x>`, #265) or a single stray one
            // (`<a@x` / `a@x>`, #270; the old paired-contains gate let these
            // through). The scan is quote-aware, so a legal RFC 5322 quoted
            // local-part carrying angles (`"a<b"@x`, even a matched `"a<b>"@x`)
            // passes — angles inside quoted strings are legal specials, and a
            // naive contains() gate would mis-reject them. Bare-angle `<a@b.c>`
            // is already normalized upstream (angles stripped), unaffected.
            // Residual honesty (#270 verify DA + Codex R1): one malformed
            // shape still passes this lite gate by design — when a display
            // name DID parse (name != nil) the extracted addr-spec is not
            // re-scanned, so a '>' embedded inside it survives
            // (`Name <a>b@x>`). And the old→new reject/pass delta is not
            // limited to `"a<b>"@x` — angles inside a CLOSED local-part
            // quoted string always pass (e.g. the fully-quoted `"<a@x>"`,
            // unmasking the pre-existing no-domain acceptance). Unterminated
            // quotes and domain-position quotes get NO exemption (R1, Codex
            // — see containsUnquotedAngle). All land as Mail-level invalid,
            // no mis-send.
            if parsed.name == nil, containsUnquotedAngle(addr) {
                failures.append("'\(raw)' is a malformed recipient (stray/unpaired angle brackets)")
                continue
            }
            // Structural: exactly one `@`, neither at start nor end.
            let atCount = addr.filter { $0 == "@" }.count
            if atCount != 1 {
                failures.append("'\(addr)' must contain exactly one '@' (got \(atCount))")
                continue
            }
            if addr.hasPrefix("@") || addr.hasSuffix("@") {
                failures.append("'\(addr)' must not start or end with '@'")
                continue
            }
        }
        guard failures.isEmpty else {
            throw MailError.invalidParameter("Invalid email address(es) in '\(field)': \(failures.joined(separator: "; "))")
        }
    }

    /// Issue #34: case-insensitive dedup within a recipient list (preserves
    /// first-seen order). Use BEFORE passing to recipientFragment to avoid
    /// duplicate `make new cc recipient` AppleScript calls for the same address.
    ///
    /// Note: cross-list dedup (cc_additional vs reply_all-derived CCs from
    /// original message) is OUT of scope for this helper — it would require
    /// fetching original-message CC headers. Document as known limitation.
    func dedupAddresses(_ addresses: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for addr in addresses {
            let key = addr.lowercased()
            if seen.insert(key).inserted {
                result.append(addr)
            }
        }
        return result
    }

    /// Issue #38: harden attachment path validation against prompt-injection
    /// exfil vectors. Three layers of defense applied in order:
    ///   1. Existence (preserved from validateFilePaths)
    ///   2. Symlink resolution (defeats `~/Documents/decoy → ~/.ssh` bypass)
    ///   3. Deny-list of sensitive directories (default-on, hardcoded)
    ///   4. Optional allow-list via `MAIL_MCP_ATTACHMENT_ROOTS` env var
    ///      (colon-separated, `~` expanded). If unset, only deny-list applies.
    ///
    /// Without these checks, a malicious / hallucinated MCP caller could pass
    /// `attachments=["/Users/X/.ssh/id_ed25519"]` and have it attached to a
    /// silent draft (combined with `save_as_draft=true` post-#33).
    ///
    /// `internal` (not `private`) so `@testable import` can exercise the helper
    /// in unit tests without going through Mail.app.
    func validateAttachmentPaths(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }

        // Issue #63: cap attachment count to mitigate DoS amplification.
        // Post-#60, each attachment adds ≈0.3s AppleScript dispatch latency
        // (between-attachment pacing) + 0.5s trailing drain. A pathological
        // caller passing N=1000 paths would block Mail.app for ≈300s. The
        // 64KB osascript script soft cap (per MailControllerComposeTests:782)
        // already caps practical N to ~200-400 before script truncation
        // kicks in (≈60-120s ceiling), but explicit count cap is cleaner and
        // matches the input-validation hardening series (#38 / #41 / #50).
        // 50 is well above realistic legitimate use cases (typical mail
        // attachments ≤ 10) but below the script-size cliff.
        let attachmentCountCap = 50
        guard paths.count <= attachmentCountCap else {
            throw MailError.invalidParameter(
                "attachments.count exceeds cap (\(paths.count) > \(attachmentCountCap)). "
                + "Mail.app cannot reliably attach this many files in a single call."
            )
        }

        let home = NSHomeDirectory()
        let denyList: [String] = [
            "\(home)/.ssh",
            "\(home)/Library/Keychains",
            "\(home)/Library/Application Support/com.apple.TCC",
            "\(home)/Library/Cookies",
            "\(home)/Library/Application Support/Google/Chrome",
            "\(home)/Library/Application Support/Safari",
            "/etc",
            "/var",
            "/private",
        ]

        // Allow-list: env var split on ":" (Unix convention); leading "~"
        // expanded to NSHomeDirectory(). nil if env var unset → no allow-list
        // restriction (only deny-list applies).
        let allowList: [String]? = ProcessInfo.processInfo
            .environment["MAIL_MCP_ATTACHMENT_ROOTS"]
            .map { raw in
                raw.split(separator: ":", omittingEmptySubsequences: true)
                    .map { String($0) }
                    .map { p in p.hasPrefix("~") ? "\(home)\(p.dropFirst())" : p }
            }

        var failures: [String] = []

        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else {
                failures.append("'\(path)' not found")
                continue
            }

            let resolved = URL(fileURLWithPath: path)
                .standardized
                .resolvingSymlinksInPath()
                .path

            if let denied = denyList.first(where: { resolved == $0 || resolved.hasPrefix("\($0)/") }) {
                failures.append("'\(path)' rejected: resolves under sensitive directory '\(denied)'")
                continue
            }

            if let allowList = allowList {
                let isAllowed = allowList.contains { allowed in
                    resolved == allowed || resolved.hasPrefix("\(allowed)/")
                }
                if !isAllowed {
                    failures.append("'\(path)' rejected: outside MAIL_MCP_ATTACHMENT_ROOTS allow-list")
                    continue
                }
            }
        }

        guard failures.isEmpty else {
            throw MailError.invalidParameter("Attachment path validation failed: \(failures.joined(separator: "; "))")
        }
    }

    /// Compose and send a new email
    func composeEmail(to: [String], subject: String, body: String, cc: [String]? = nil, bcc: [String]? = nil, attachments: [String]? = nil, accountName: String? = nil, format: BodyFormat = .plain, sanitizeLinks: Bool = false, fromAddress: String? = nil, requireWrapperFree: Bool = false) throws -> String {
        if let attachments = attachments { try validateAttachmentPaths(attachments) }
        // Issue #41: validate every recipient field (to / cc / bcc) at the boundary.
        try validateEmailAddresses(to, field: "to")
        if let cc = cc { try validateEmailAddresses(cc, field: "cc") }
        if let bcc = bcc { try validateEmailAddresses(bcc, field: "bcc") }
        // Issue #131: validate from_address with the same address-format
        // discipline applied to recipients. Mail.app's `sender` property
        // accepts plain addr-spec; multiple-@ / control-char inputs would
        // fail with opaque AppleScript errors otherwise.
        if let from = fromAddress, !from.isEmpty {
            try validateEmailAddresses([from], field: "from_address")
        }
        // Note: `accountName` parameter is intentionally accepted but unused
        // here (legacy/dead since the tool was added — see #131 issue body).
        // The actual sender selection is wired through `fromAddress`. Kept
        // for backward compat with any Swift caller still passing it; no
        // production caller does so.

        // #175: prefer the wrapper-free mailto path (native compose pipeline →
        // no Apple-Mail-URLShare/blockquote-cite wrapper). Falls back to the
        // legacy AppleScript injection (which wraps the body) on any failure,
        // for markdown/html, for a custom sender, without Accessibility, or
        // when disabled via env. See MailtoCompose.swift.
        // #237: the fallback is no longer silent — the named reason goes to
        // stderr AND onto the returned result string.
        // #239: strict mode — a caller that requires a wrapper-free body gets a
        // clean failure (named reason + alternatives) instead of a silently
        // wrapped draft; a clean-path error propagates with NO legacy fallback.
        if requireWrapperFree {
            if let reason = mailtoIneligibilityReasonForCall(
                format: format, fromAddress: fromAddress, subject: subject,
                attachments: attachments,
                recipients: to + (cc ?? []) + (bcc ?? [])) {
                throw MailError.invalidParameter(requireWrapperFreeRefusal(reason: reason))
            }
            do {
                return try composeViaMailto(
                    to: to, subject: subject, body: body, cc: cc, bcc: bcc,
                    attachments: attachments, send: true)
            } catch where isPostDispatchError(error) {
                // #239 verify REQUIRED: same friendly guardrail as the default
                // path — a raw POSTDISPATCH token invites an auto-retrying
                // caller to re-send. Still no legacy fallback.
                throw unknownSendStateError(error)
            }
        }
        // #241: the clean-or-disclosed-legacy control flow lives in the tested
        // routeWrapperFreeCompose router; this site only supplies the real
        // closures (WrapperFreeRouteTests locks both the router behavior and,
        // via source scan, this wiring).
        return try routeWrapperFreeCompose(
            ineligibilityReason: mailtoIneligibilityReasonForCall(
                format: format, fromAddress: fromAddress, subject: subject,
                attachments: attachments,
                recipients: to + (cc ?? []) + (bcc ?? [])),
            cleanPath: {
                try composeViaMailto(
                    to: to, subject: subject, body: body, cc: cc, bcc: bcc,
                    attachments: attachments, send: true)
            },
            legacyPath: {
                let script = try buildComposeEmailScript(
                    to: to,
                    subject: subject,
                    body: body,
                    cc: cc,
                    bcc: bcc,
                    attachments: attachments,
                    format: format,
                    sanitizeLinks: sanitizeLinks,
                    fromAddress: fromAddress
                )
                return try runScript(script)
            },
            disclosure: { legacyPathDisclosure(reason: $0) },
            warnIneligible: { warnMailtoIneligible($0) },
            warnTriedAndFailed: { warnMailtoFallback($0) },
            fallbackReason: { "mailto GUI path failed: \(clampedErrorEcho($0.localizedDescription))" },
            // #242: once the send keystroke has been dispatched the send state
            // is UNKNOWN — refuse the legacy re-send (duplicate outbound risk)
            // and tell the caller what to check instead.
            shouldFallback: { !isPostDispatchError($0) },
            mapNoFallbackError: { unknownSendStateError($0) })
    }

    /// #175/#237 — nil iff this compose call should use the wrapper-free mailto
    /// path; otherwise the named reason for routing to the legacy path. Probes
    /// Accessibility + the env escape hatch at call time; custom sender
    /// (`fromAddress`) and an empty subject both route to the legacy path (mailto
    /// can't pick a non-default account; the GUI dispatch guard identifies the
    /// compose window by its title = subject).
    private func mailtoIneligibilityReasonForCall(format: BodyFormat, fromAddress: String?, subject: String, attachments: [String]? = nil, recipients: [String] = []) -> String? {
        if let override = ineligibilityOverride { return override() }
        return mailtoIneligibilityReason(
            format: format,
            accessibilityTrusted: AccessibilityStatus.isTrusted,
            disabledByEnv: mailtoComposeDisabledByEnv(),
            hasCustomSender: (fromAddress?.isEmpty == false),
            hasSubject: !subject.isEmpty,
            attachmentsGuiSafe: attachmentPathsGuiSafe(attachments),
            recipientsAddrSpecOnly: !anyRecipientHasDisplayName(recipients)
        )
    }

    /// #237 — surface (never swallow) that a compose call never even attempted
    /// the wrapper-free mailto path. Sibling of `warnMailtoFallback`: that one
    /// fires when mailto was TRIED and failed; this one fires when the call was
    /// ineligible from the start (custom sender / format / no subject / no
    /// Accessibility / env hatch). The 2026-07-09 #237 regression report came
    /// from exactly this silent branch.
    private func warnMailtoIneligible(_ reason: String) {
        let msg = "mailto clean-compose path skipped (#237): \(reason); "
            + "using legacy AppleScript injection — body will be wrapped in "
            + "<blockquote type=\"cite\"> (looks quoted on some mobile clients)\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }

    /// #175 — run the wrapper-free mailto compose path. Builds the percent-encoded
    /// URL, refuses over-long URLs (→ caller falls back; avoids silent body
    /// truncation), and runs the GUI script with the user's clipboard preserved
    /// at full fidelity when attachments are involved (the script sets the
    /// clipboard per-attachment for the Go-to-folder paste).
    private func composeViaMailto(
        to: [String], subject: String, body: String,
        cc: [String]?, bcc: [String]?, attachments: [String]?, send: Bool
    ) throws -> String {
        let url = buildMailtoURL(to: to, subject: subject, body: body, cc: cc, bcc: bcc)
        guard url.count <= maxMailtoURLLength else {
            throw MailError.scriptFailed(
                message: "mailto URL too long (\(url.count) > \(maxMailtoURLLength) chars)",
                code: -1)
        }
        let script = buildMailtoComposeScript(
            url: url, subject: subject, attachments: attachments ?? [], send: send)
        if attachments?.isEmpty == false {
            return try withClipboardPreserved { try runScript(script) }
        }
        return try runScript(script)
    }

    /// #175 — preserve the user's clipboard (all flavors) across a closure that
    /// mutates it. The mailto attach path sets the clipboard to each attachment
    /// path for the Go-to-folder paste; this snapshots every pasteboard item's
    /// types+data into detached copies and restores them in a `defer` (so the
    /// clipboard is restored even if the GUI script throws). Full-fidelity
    /// (image / RTF / file-promise survive), unlike an AppleScript `the clipboard
    /// as text` round-trip (#175 verify — Codex).
    private func withClipboardPreserved<T>(_ body: () throws -> T) rethrows -> T {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        defer {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        return try body()
    }

    /// #175 — surface (never swallow) a mailto-path failure before falling back
    /// to the legacy injection path. Mirrors the save_attachment fast-path
    /// fallback logging precedent (the `r-must-direct-db` observability rule).
    private func warnMailtoFallback(_ error: Error) {
        let msg = "mailto clean-compose path failed (#175): "
            + "\(error.localizedDescription); falling back to AppleScript injection "
            + "— body will be wrapped in <blockquote type=\"cite\"> (looks quoted on some mobile clients)\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }

    /// #218 — surface (never swallow) a reply/forward clean-paste failure before
    /// falling back to the legacy injection path. Mirrors `warnMailtoFallback`
    /// (the `r-must-direct-db` observability rule): a silent fallback would hide
    /// the wrapper regression returning.
    private func warnReplyForwardPasteFallback(_ error: Error) {
        let msg = "reply/forward clean-paste path failed (#218): "
            + "\(error.localizedDescription); falling back to AppleScript injection "
            + "— new body will be wrapped in <blockquote type=\"cite\"> (looks quoted on some mobile clients)\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }

    /// #218/#229 — nil iff this reply/forward call should use the clean
    /// native-verb + paste path; otherwise the named reason for the legacy
    /// route. Probes Accessibility + the env escape hatch at call time.
    private func pasteReplyForwardIneligibilityReasonForCall(format: BodyFormat) -> String? {
        if let override = ineligibilityOverride { return override() }
        return pasteReplyForwardIneligibilityReason(
            format: format,
            accessibilityTrusted: AccessibilityStatus.isTrusted,
            disabledByEnv: replyForwardPasteDisabledByEnv()
        )
    }

    /// #229 — surface (never swallow) that a reply/forward call never even
    /// attempted the clean paste path. Sibling of `warnReplyForwardPasteFallback`:
    /// that one fires when the paste path was TRIED and failed; this one fires
    /// when the call was ineligible from the start (format / no Accessibility /
    /// env hatch) — previously a fully silent branch.
    private func warnPasteReplyIneligible(_ reason: String) {
        let msg = "reply/forward clean-paste path skipped (#229): \(reason); "
            + "using legacy AppleScript injection — the NEW body will be wrapped in "
            + "<blockquote type=\"cite\"> (looks quoted on some mobile clients)\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }

    /// Reply to an email. Optionally add extra CC, attach files, and/or save as draft instead of sending.
    func replyEmail(id: String, mailbox: String, accountName: String, body: String, replyAll: Bool = false, ccAdditional: [String]? = nil, attachments: [String]? = nil, saveAsDraft: Bool = false, format: BodyFormat = .plain, sanitizeLinks: Bool = false, accountId: String? = nil) throws -> String {
        if let attachments = attachments { try validateAttachmentPaths(attachments) }
        // Issue #41 + #34: validate cc_additional then dedup case-insensitively
        // (within the user-supplied list; cross-list dedup vs reply_all-derived
        // CCs requires fetching original CCs — out of scope, see #34).
        let dedupedCC: [String]?
        if let cc = ccAdditional {
            try validateEmailAddresses(cc, field: "cc_additional")
            dedupedCC = dedupAddresses(cc)
        } else {
            dedupedCC = nil
        }
        let ref = resolveMsgRef(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName)

        // #218: prefer the wrapper-free native-verb + paste path. Mail's native
        // `reply` builds the quoted original itself (correct cite-blockquote +
        // threading headers) and we paste ONLY the new body at the cursor — never
        // `set content`/`set html content`, so the user's new text is not wrapped
        // in the URLShare/cite wrapper. The clean path needs NO #43 pre-fetch
        // (Mail quotes the original). Falls back to the legacy injection path
        // (wrapped new body) for markdown/html, without Accessibility, when
        // disabled via env (CHE_MAIL_DISABLE_PASTE_REPLY), or on any GUI failure.
        // #229: the fallback is no longer silent — the named reason goes to
        // stderr AND onto the returned result string (mirrors #237 compose).
        // #241: control flow lives in the tested router (see composeEmail).
        // The legacy closure keeps the #43 pre-fetch + build + run sequence.
        func runLegacyReply() throws -> String {
            // Issue #43: pre-fetch unconditionally — plain mode also needs originalPlain
            // so composeReplyPlainText can build RFC 3676 quoted body. AppleScript's
            // `& content` against a freshly-created outgoing message reads as empty
            // before Mail.app's GUI populates it, which silently dropped the quoted
            // original from every plain reply since b8a4a89 (initial release).
            //
            // Round-1 hardening (#43 verify Logic #4 / DA-3): pre-fetch failure
            // (sandbox -1743, message deleted, ICloud server-side body) must not
            // hard-fail the whole reply. Fall back to "no quote" so the user's
            // body is still preserved and the reply can still be sent/saved.
            let originalHTML: String?
            let originalPlain: String
            do {
                let fetched = try runScript(buildFetchOriginalContentScript(messageRef: ref))
                let parsed = parseFetchedOriginalContent(fetched)
                originalHTML = parsed.html
                originalPlain = parsed.plain
            } catch {
                originalHTML = nil
                originalPlain = ""
            }

            // #134: use the (id:mailbox:accountId:accountName:) overload — the
            // resolveMsgRef call is internalized there, so ComposeScriptBuilderTests
            // locks the wiring (reverting resolveMsgRef→msgRef inside the overload
            // would now fail the unit test). Pre-fetch path still computes `ref`
            // inline because it threads through buildFetchOriginalContentScript;
            // wiring lock for the fetch path is out of #134's scope.
            let script = try buildReplyEmailScript(
                id: id,
                mailbox: mailbox,
                accountId: accountId,
                accountName: accountName,
                userBody: body,
                userFormat: format,
                replyAll: replyAll,
                ccAdditional: dedupedCC,
                attachments: attachments,
                saveAsDraft: saveAsDraft,
                originalHTML: originalHTML,
                originalPlain: originalPlain,
                sanitizeLinks: sanitizeLinks
            )
            return try runScript(script)
        }

        // #229: a reply always injects a new body on the legacy path → always disclose.
        return try routeWrapperFreeCompose(
            ineligibilityReason: pasteReplyForwardIneligibilityReasonForCall(format: format),
            cleanPath: {
                let pasteScript = buildReplyEmailPasteScript(
                    messageRef: ref,
                    newBody: body,
                    replyAll: replyAll,
                    ccAdditional: dedupedCC,
                    attachments: attachments,
                    saveAsDraft: saveAsDraft
                )
                // Always preserve the user's clipboard — the paste path sets it to
                // the new body for the ⌘V (full-fidelity restore, like #175 attach).
                return try withClipboardPreserved { try runScript(pasteScript) }
            },
            legacyPath: { try runLegacyReply() },
            disclosure: { legacyReplyPathDisclosure(reason: $0) },
            warnIneligible: { warnPasteReplyIneligible($0) },
            warnTriedAndFailed: { warnReplyForwardPasteFallback($0) },
            fallbackReason: { "paste GUI path failed: \(clampedErrorEcho($0.localizedDescription))" },
            // #254: once the send keystroke has been dispatched (or the
            // success-path tail errored — mail definitely sent), refuse the
            // legacy re-send and surface unknown-send-state (#242 pattern).
            shouldFallback: { !isPostDispatchError($0) },
            mapNoFallbackError: {
                MailError.scriptFailed(
                    message: "the send keystroke was already dispatched but a GUI step failed "
                        + "afterwards — the send state is UNKNOWN and the reply/forward may already "
                        + "be on the wire. NOT retrying via the legacy path (that could send a "
                        + "duplicate). Check Mail's Sent mailbox / Outbox and the original thread "
                        + "before re-sending. The compose window (if still open) was left untouched "
                        + "for inspection. Original error: "
                        + clampedErrorEcho($0.localizedDescription),
                    code: -1)
            })
    }

    /// Forward an email
    func forwardEmail(id: String, mailbox: String, accountName: String, to: [String], body: String? = nil, format: BodyFormat = .plain, sanitizeLinks: Bool = false, accountId: String? = nil) throws -> String {
        // Issue #41: validate forward recipients at the boundary.
        try validateEmailAddresses(to, field: "to")
        let ref = resolveMsgRef(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName)

        // #218: prefer the wrapper-free native-verb + paste path — but ONLY when a
        // NEW body is provided. A forward with no body injects nothing, so the
        // legacy path is already wrapper-free (`buildForwardEmailScript` with
        // userBody: nil omits the content mutation). Mail's native `forward` builds
        // the quoted original; we paste only the new note at the cursor — never
        // `set content`/`set html content`. Falls back to legacy injection for
        // markdown/html, without Accessibility, when disabled via env, or on any
        // GUI failure.
        // #229: when a NEW body is present, the fallback is no longer silent —
        // the named reason goes to stderr AND onto the returned result string.
        // A forward with NO body never gets a disclosure suffix: the legacy
        // path injects nothing there and is already wrapper-free.
        // #241: control flow lives in the tested router (see composeEmail).
        // The legacy closure is shared with the bodyless path below.
        func runLegacyForward() throws -> String {
            // Issue #44 (mirrors #43): pre-fetch unconditionally when body is provided.
            // Plain mode also needs originalPlain so composeReplyPlainText can build
            // RFC 3676 quoted body — same root cause as #43 (AppleScript `& content`
            // against fresh outgoing message returns empty before GUI populates it).
            // Wrap in try/catch for graceful degrade (mirror #43 round-1 hardening):
            // pre-fetch failure (sandbox -1743, deleted message) must not hard-fail
            // the whole forward.
            let originalHTML: String?
            let originalPlain: String
            if body != nil {
                do {
                    let fetched = try runScript(buildFetchOriginalContentScript(messageRef: ref))
                    let parsed = parseFetchedOriginalContent(fetched)
                    originalHTML = parsed.html
                    originalPlain = parsed.plain
                } catch {
                    originalHTML = nil
                    originalPlain = ""
                }
            } else {
                originalHTML = nil
                originalPlain = ""
            }

            // #134: use the (id:mailbox:accountId:accountName:) overload — see
            // the matching note in replyEmail above.
            let script = try buildForwardEmailScript(
                id: id,
                mailbox: mailbox,
                accountId: accountId,
                accountName: accountName,
                to: to,
                userBody: body,
                userFormat: format,
                originalHTML: originalHTML,
                originalPlain: originalPlain,
                sanitizeLinks: sanitizeLinks
            )
            return try runScript(script)
        }

        // #229: disclose only when a new body would be injected by the legacy
        // path — a bodyless forward injects nothing (already wrapper-free), so
        // it bypasses the router entirely and never gets a suffix.
        if let newBody = body {
            return try routeWrapperFreeCompose(
                ineligibilityReason: pasteReplyForwardIneligibilityReasonForCall(format: format),
                cleanPath: {
                    let pasteScript = buildForwardEmailPasteScript(
                        messageRef: ref, to: to, newBody: newBody)
                    return try withClipboardPreserved { try runScript(pasteScript) }
                },
                legacyPath: { try runLegacyForward() },
                disclosure: { legacyReplyPathDisclosure(reason: $0) },
                warnIneligible: { warnPasteReplyIneligible($0) },
                warnTriedAndFailed: { warnReplyForwardPasteFallback($0) },
                fallbackReason: { "paste GUI path failed: \(clampedErrorEcho($0.localizedDescription))" },
            // #254: once the send keystroke has been dispatched (or the
            // success-path tail errored — mail definitely sent), refuse the
            // legacy re-send and surface unknown-send-state (#242 pattern).
            shouldFallback: { !isPostDispatchError($0) },
            mapNoFallbackError: {
                MailError.scriptFailed(
                    message: "the send keystroke was already dispatched but a GUI step failed "
                        + "afterwards — the send state is UNKNOWN and the reply/forward may already "
                        + "be on the wire. NOT retrying via the legacy path (that could send a "
                        + "duplicate). Check Mail's Sent mailbox / Outbox and the original thread "
                        + "before re-sending. The compose window (if still open) was left untouched "
                        + "for inspection. Original error: "
                        + clampedErrorEcho($0.localizedDescription),
                    code: -1)
            })
        }
        return try runLegacyForward()
    }

    // MARK: - Draft Operations

    /// List drafts (#174: resolves the per-account drafts mailbox through the
    /// unified `drafts mailbox`'s children instead of the pre-#174 hardcoded
    /// `whose name is "Drafts"` lookup, which failed -1719 on Gmail accounts
    /// whose drafts mailbox carries a localized name like `草稿`).
    func listDrafts(accountName: String, accountId: String? = nil) throws -> [[String: Any]] {
        let script = buildListDraftsScript(accountId: accountId, accountName: accountName)
        do {
            let subjects = try runScriptAsList(script)
            return subjects.map { subject in
                ["subject": subject]
            }
        } catch {
            // #185: route every list_drafts script error through the pure
            // `translateListDraftsScriptError` (ListDraftsScriptBuilder.swift, alongside
            // the 9174 constant). The 9174 no-match becomes an actionable operationFailed
            // carrying `listDraftsNoMatchHint`; any other error rethrows unchanged. A pure
            // function so the whole code-path contract (guard + wrapping + non-9174
            // propagation) is unit-testable without an actor runner seam. Behaviorally
            // identical to the prior selective `catch where code == 9174` (PR #181 #18).
            throw translateListDraftsScriptError(error, accountId: accountId, accountName: accountName)
        }
    }

    /// Create a draft
    func createDraft(to: [String], subject: String, body: String, cc: [String]? = nil, bcc: [String]? = nil, attachments: [String]? = nil, accountName: String? = nil, format: BodyFormat = .plain, sanitizeLinks: Bool = false, fromAddress: String? = nil, requireWrapperFree: Bool = false) throws -> String {
        if let attachments = attachments { try validateAttachmentPaths(attachments) }
        // Issue #41: validate every recipient field (to / cc / bcc) at the boundary (#107).
        try validateEmailAddresses(to, field: "to")
        if let cc = cc { try validateEmailAddresses(cc, field: "cc") }
        if let bcc = bcc { try validateEmailAddresses(bcc, field: "bcc") }
        // #131: validate sender address (see composeEmail).
        if let from = fromAddress, !from.isEmpty {
            try validateEmailAddresses([from], field: "from_address")
        }

        // #239: strict mode (see composeEmail above).
        if requireWrapperFree {
            if let reason = mailtoIneligibilityReasonForCall(
                format: format, fromAddress: fromAddress, subject: subject,
                attachments: attachments,
                recipients: to + (cc ?? []) + (bcc ?? [])) {
                throw MailError.invalidParameter(requireWrapperFreeRefusal(reason: reason))
            }
            return try composeViaMailto(
                to: to, subject: subject, body: body, cc: cc, bcc: bcc,
                attachments: attachments, send: false)
        }

        // #175: prefer the wrapper-free mailto path (save draft via ⌘S);
        // graceful fallback to legacy injection. See composeEmail above.
        // #237: the fallback is no longer silent — the named reason goes to
        // stderr AND onto the returned result string.
        // #241: control flow lives in the tested router (see composeEmail).
        return try routeWrapperFreeCompose(
            ineligibilityReason: mailtoIneligibilityReasonForCall(
                format: format, fromAddress: fromAddress, subject: subject,
                attachments: attachments,
                recipients: to + (cc ?? []) + (bcc ?? [])),
            cleanPath: {
                try composeViaMailto(
                    to: to, subject: subject, body: body, cc: cc, bcc: bcc,
                    attachments: attachments, send: false)
            },
            legacyPath: {
                let script = try buildCreateDraftScript(
                    to: to,
                    subject: subject,
                    body: body,
                    cc: cc,
                    bcc: bcc,
                    attachments: attachments,
                    format: format,
                    sanitizeLinks: sanitizeLinks,
                    fromAddress: fromAddress
                )
                return try runScript(script)
            },
            disclosure: { legacyPathDisclosure(reason: $0) },
            warnIneligible: { warnMailtoIneligible($0) },
            warnTriedAndFailed: { warnMailtoFallback($0) },
            fallbackReason: { "mailto GUI path failed: \(clampedErrorEcho($0.localizedDescription))" })
    }

    // MARK: - Attachment Operations

    /// List attachments of an email
    func listAttachments(id: String, mailbox: String, accountName: String, accountId: String? = nil) throws -> [[String: Any]] {
        let ref = msgRef(id, mailbox: mailbox, account: accountName, accountId: accountId)
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

    /// Save attachment to disk.
    ///
    /// 5-arg overload retained as the #112 byte-identity referent for
    /// `buildSaveAttachmentScript(accountId: nil)`. No live caller (the Server
    /// `save_attachment` handler uses the #101 6-arg overload), but #180 still
    /// routes its `msgRef` through the `resolveMsgRef` chokepoint — so this path
    /// is no longer an inline-legacy bypass while staying byte-identical at
    /// `accountId: nil`.
    func saveAttachment(id: String, mailbox: String, accountName: String, attachmentName: String, savePath: String) throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set msg to \(ref)
            repeat with att in mail attachments of msg
                if name of att is "\(appleScriptEscape(attachmentName))" then
                    save att in POSIX file "\(appleScriptEscape(savePath))"
                    return "Attachment saved to \(appleScriptEscape(savePath))"
                end if
            end repeat
            return "Attachment not found"
        end tell
        """
        return try runScript(script)
    }

    /// `save_attachment` overload with optional `accountId` (UUID) for
    /// multi-account-same-display_name disambiguation (#101).
    ///
    /// When `accountId` is non-nil and non-empty, the underlying AppleScript
    /// uses Mail.app's `(account id "<UUID>")` selector — globally unique,
    /// no collision risk. Otherwise behavior is identical to the 5-arg
    /// `saveAttachment(id:mailbox:accountName:...)` overload above.
    ///
    /// Script construction is delegated to `buildSaveAttachmentScript` (in
    /// `SaveAttachmentScriptBuilder.swift`) so the AppleScript generation
    /// is testable without spinning up the actor — same pattern as
    /// `ComposeScriptBuilder`.
    func saveAttachment(
        id: String,
        mailbox: String,
        accountId: String?,
        accountName: String,
        attachmentName: String,
        savePath: String
    ) throws -> String {
        let script = buildSaveAttachmentScript(
            id: id,
            mailbox: mailbox,
            accountId: accountId,
            accountName: accountName,
            attachmentName: attachmentName,
            savePath: savePath
        )
        return try runScript(script)
    }

    /// Best-effort `save_attachment` for a server-side-only (`not_downloaded`)
    /// attachment (#272, Option B): nudge Mail to fetch the message, then
    /// re-attempt the save on a bounded poll loop until it lands or the budget
    /// is spent.
    ///
    /// This is **best-effort and unverified** — see `AttachmentDownloadScriptBuilder`
    /// for why Mail exposes no real download verb. On timeout it fails
    /// **honestly** with the `not_downloaded` guidance (never a false "saved").
    /// Only invoked when the caller opted in via `download_if_missing` AND local
    /// state already proved the part is not downloaded (`shouldAttemptDownloadRetry`).
    ///
    /// - Note: triggering the fetch mutates local Mail state (server→local), so
    ///   this stays on the AppleScript side — allowed by `r-must-direct-db` for
    ///   the C/U/D (state-changing) class; detection stayed on the SQLite path.
    func saveAttachmentRetryingForDownload(
        id: String,
        mailbox: String,
        accountId: String?,
        accountName: String,
        attachmentName: String,
        savePath: String,
        policy: DownloadRetryPolicy = .default
    ) async throws -> String {
        // 1. Nudge Mail to materialize the message (best-effort). Errors are
        //    non-fatal — the save-retry below is the real success test — but log
        //    them so a no-op fetch is distinguishable from a working one (the
        //    r-must-direct-db stderr-observability convention).
        let trigger = buildTriggerDownloadScript(
            id: id, mailbox: mailbox, accountId: accountId, accountName: accountName)
        do {
            _ = try runScript(trigger)
        } catch {
            FileHandle.standardError.write(Data(
                ("download_if_missing: fetch-trigger failed for \"\(attachmentName)\": "
                 + "\(error.localizedDescription); continuing to poll-retry the save\n").utf8))
        }

        // 2. Poll: re-attempt the save until it succeeds or the wall-clock budget
        //    is spent. A downloaded attachment saves cleanly; a still-server-side
        //    one raises the generic -10000 (unfetched-binary class) — keep waiting.
        //    The loop is bounded by BOTH a real deadline (each save is itself a
        //    ~1-2s Mail IPC that a fixed sleep-count would ignore — so the deadline
        //    keeps real elapsed ≈ policy.timeout) AND `maxAttempts` as a hard cap
        //    (belt-and-suspenders if the clock misbehaves; the range is always
        //    valid since maxAttempts ≥ 1).
        let saveScript = buildSaveAttachmentScript(
            id: id, mailbox: mailbox, accountId: accountId, accountName: accountName,
            attachmentName: attachmentName, savePath: savePath)
        let intervalNanos = UInt64(min(max(0, policy.pollInterval), policy.timeout) * 1_000_000_000)
        let deadline = Date().addingTimeInterval(max(0, policy.timeout))
        for _ in 1...policy.maxAttempts {
            // Wait BEFORE re-checking: the fetch is asynchronous, so even the
            // first poll gives Mail one interval to land the download.
            try await Task.sleep(nanoseconds: intervalNanos)
            do {
                let result = try runScript(saveScript)
                // "Attachment saved to ..." = the binary is now local.
                if result.hasPrefix("Attachment saved") { return result }
                // A non-throwing NON-saved result ("Attachment not found") is a
                // DEFINITIVE negative — the named part isn't on this message (a
                // name-matching problem, not a download delay). Don't burn the
                // budget polling it; surface it now with the honest cause.
                throw MailError.operationFailed(
                    "save_attachment could not find an attachment named \"\(attachmentName)\" "
                    + "on the message (download_if_missing aborted — this is not a download problem).")
            } catch MailError.scriptFailed(let message, let code) {
                // -10000 = still unfetched → keep polling. A SPECIFIC code
                // (bad account/mailbox, permissions, disk full) is terminal —
                // retrying cannot fix it, so surface it immediately.
                if code != -10000 {
                    throw MailError.scriptFailed(message: message, code: code)
                }
            }
            if Date() >= deadline { break }   // wall-clock budget spent
        }
        // Budget spent without the attachment landing — honest failure.
        throw MailError.operationFailed(
            "Best-effort download did not complete within \(Int(policy.timeout))s. "
            + MailSQLiteError.attachmentNotDownloaded(name: attachmentName).localizedDescription)
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
            set enabled of rule "\(appleScriptEscape(name))" to \(enabled)
            return "Rule '\(appleScriptEscape(name))' \(enabled ? "enabled" : "disabled")"
        end tell
        """
        return try runScript(script)
    }

    /// Get detailed rule information
    func getRuleDetails(name: String) throws -> [String: Any] {
        let enabledScript = """
        tell application "Mail"
            get enabled of rule "\(appleScriptEscape(name))"
        end tell
        """

        let allConditionsScript = """
        tell application "Mail"
            get all conditions must be met of rule "\(appleScriptEscape(name))"
        end tell
        """

        let stopScript = """
        tell application "Mail"
            get stop evaluating rules of rule "\(appleScriptEscape(name))"
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

    /// Create a simple mail rule.
    ///
    /// Delegates AppleScript generation to `buildCreateRuleScript` in
    /// `CreateRuleScriptBuilder.swift` (#140 — sister fix to #116). The
    /// builder enforces `ruleQualifierWhitelist` membership via
    /// `precondition` as defense-in-depth; the user-facing reject path
    /// lives in `Server.swift`'s `create_rule` handler, which validates
    /// before reaching this method.
    ///
    /// Signature unchanged from pre-extraction (#140 commit `... → ...`);
    /// for valid inputs the AppleScript output is byte-identical to the
    /// pre-extraction inline string (pinned by
    /// `CreateRuleScriptBuilderTests.testBuildCreateRuleScript_byteEquivalenceWithInlineImplementation`).
    func createRule(name: String, conditions: [[String: String]], actions: [String: Any]) throws -> String {
        let script = buildCreateRuleScript(name: name, conditions: conditions, actions: actions)
        return try runScript(script)
    }

    /// Delete a rule
    func deleteRule(name: String) throws -> String {
        let script = """
        tell application "Mail"
            delete rule "\(appleScriptEscape(name))"
            return "Rule '\(appleScriptEscape(name))' deleted"
        end tell
        """
        return try runScript(script)
    }

    // MARK: - Mail Check & Sync Operations

    /// Check for new mail.
    ///
    /// #191: optional `accountId` adds the UUID-selector escape hatch (mirrors the
    /// #104/#176 account_id overload). Delegates to `buildCheckForNewMailScript`
    /// (pure, unit-tested); the name-mode / check-all output is byte-identical to
    /// the pre-#191 inline script.
    func checkForNewMail(accountName: String? = nil, accountId: String? = nil) throws -> String {
        let script = buildCheckForNewMailScript(accountId: accountId, accountName: accountName)
        return try runScript(script)
    }

    /// Synchronize IMAP account.
    ///
    /// #191: optional `accountId` adds the UUID-selector escape hatch (mirrors the
    /// #104/#176 account_id overload). Delegates to `buildSynchronizeAccountScript`
    /// (pure, unit-tested); the name-mode output is byte-identical to the pre-#191
    /// inline script.
    func synchronizeAccount(accountName: String, accountId: String? = nil) throws -> String {
        let script = buildSynchronizeAccountScript(accountId: accountId, accountName: accountName)
        return try runScript(script)
    }

    // MARK: - Advanced Email Operations

    /// Copy email to another mailbox
    func copyEmail(id: String, fromMailbox: String, toMailbox: String, accountName: String, accountId: String? = nil) throws -> String {
        let script = buildCopyEmailScript(
            id: id, fromMailbox: fromMailbox, toMailbox: toMailbox,
            accountId: accountId, accountName: accountName
        )
        return try runScript(script)
    }

    /// Set flag color (0-6: red, orange, yellow, green, blue, purple, gray; -1 to clear)
    func setFlagColor(id: String, mailbox: String, accountId: String? = nil, accountName: String, colorIndex: Int) throws -> String {
        let script = buildSetFlagColorScript(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName, colorIndex: colorIndex)
        return try runScript(script)
    }

    /// Set email background color
    func setBackgroundColor(id: String, mailbox: String, accountId: String? = nil, accountName: String, color: String) throws -> String {
        // Valid colors: blue, gray, green, none, orange, purple, red, yellow
        let script = buildSetBackgroundColorScript(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName, color: color)
        return try runScript(script)
    }

    /// Mark email as junk or not junk
    func markAsJunk(id: String, mailbox: String, accountId: String? = nil, accountName: String, isJunk: Bool) throws -> String {
        let script = buildMarkAsJunkScript(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName, isJunk: isJunk)
        return try runScript(script)
    }

    /// Get all email headers
    func getEmailHeaders(id: String, mailbox: String, accountName: String, accountId: String? = nil) throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName, accountId: accountId)
        let script = """
        tell application "Mail"
            get all headers of \(ref)
        end tell
        """
        return try runScript(script)
    }

    /// Get email source (raw message)
    func getEmailSource(id: String, mailbox: String, accountName: String, accountId: String? = nil) throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName, accountId: accountId)
        let script = """
        tell application "Mail"
            get source of \(ref)
        end tell
        """
        return try runScript(script)
    }

    /// Redirect email (different from forward - keeps original sender).
    ///
    /// `accountId` (UUID), when non-nil/non-empty, disambiguates accounts that
    /// share a display_name (#104 sweep). Script construction is delegated to
    /// `buildRedirectEmailScript` (`RedirectEmailScriptBuilder.swift`).
    func redirectEmail(id: String, mailbox: String, accountName: String, to: [String], accountId: String? = nil) throws -> String {
        // Issue #41 (consistency with compose/reply/forward — closes #133):
        // validate redirect recipients at the boundary. Pre-fix the AppleScript
        // builder simply `appleScriptEscape`d the addresses (no injection
        // vector) but a malformed address would land in Mail.app and surface
        // as an opaque AppleScript error or silent undeliverable redirect.
        try validateEmailAddresses(to, field: "to")
        let script = buildRedirectEmailScript(
            id: id,
            mailbox: mailbox,
            accountId: accountId,
            accountName: accountName,
            to: to
        )
        return try runScript(script)
    }

    /// Get email metadata (was forwarded, replied to, redirected)
    func getEmailMetadata(id: String, mailbox: String, accountName: String, accountId: String? = nil) throws -> [String: Any] {
        let ref = msgRef(id, mailbox: mailbox, account: accountName, accountId: accountId)

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
            get content of signature "\(appleScriptEscape(name))"
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
    /// Special mailbox names.
    ///
    /// #179: when an account selector (`accountId` / `accountName`) is supplied,
    /// returns *that account's* per-account special-mailbox real names (localized /
    /// provider) via the unified-children reverse-lookup; otherwise returns the
    /// app-level unified names unchanged (backward-compat). Default-nil parameters
    /// keep existing no-arg callers source-compatible.
    func getSpecialMailboxes(accountId: String? = nil, accountName: String? = nil) throws -> [String: Any] {
        // Per-account mode (#179): an account selector is supplied.
        let hasAccount = !(accountId ?? "").isEmpty || !(accountName ?? "").isEmpty
        if hasAccount {
            let script = buildSpecialMailboxNamesScript(accountId: accountId, accountName: accountName ?? "")
            let raw = try runScriptAsList(script)  // [matchedId, matchedName, matchCount, n0…n4 (leaf), p0…p4 (full path, #268)] for drafts/sent/trash/junk/inbox (#249 lifted the inbox deferral)
            // Pure parse + pure throw-translation (both unit-tested without the actor):
            // .resolved → canonical metadata + present special names (absent omitted, D3);
            // .noMatch → operationFailed; .ambiguous → invalidParameter (#179).
            let resolution = resolveSpecialMailboxesResult(raw)
            let obj = try specialMailboxesResultOrThrow(resolution, accountId: accountId, accountName: accountName ?? "")
            return obj.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
        }

        // Unified mode (unchanged): app-level special mailbox names.
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
            extract name from "\(appleScriptEscape(address))"
        end tell
        """
        return try runScript(script)
    }

    /// Extract email address from full address string
    func extractAddressFrom(address: String) throws -> String {
        let script = """
        tell application "Mail"
            extract address from "\(appleScriptEscape(address))"
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
            mailto "\(appleScriptEscape(url))"
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
            import Mail mailbox POSIX file "\(appleScriptEscape(path))"
            return "Mailbox imported from \(appleScriptEscape(path))"
        end tell
        """
        return try runScript(script)
    }

    // MARK: - Helpers

    /// Generate AppleScript expression to reference a mailbox by display name.
    /// `mailbox "X" of account "Y"` fails for Gmail localized names (e.g. "寄件備份").
    /// `first mailbox of account "Y" whose name is "X"` always works.
    /// #180: delegates to the `resolveMailboxRef` chokepoint instead of inlining
    /// the legacy `account "<name>" whose name is "<path>"` form. Byte-identical
    /// for non-nested names at `accountId: nil` (proven against the prior inline
    /// body), and now inherits #174 nested-mailbox container chains + #101/#176
    /// account-UUID disambiguation when `accountId` is threaded through.
    private func mailboxRef(_ mailbox: String, account: String, accountId: String? = nil) -> String {
        return resolveMailboxRef(mailbox: mailbox, accountId: accountId, accountName: account)
    }

    /// Generate AppleScript reference to find a message by its numeric id.
    /// Apple Mail's `message id` refers to the RFC822 Message-ID (string),
    /// but `id` is the internal numeric identifier returned by search/list.
    /// We must use `first message ... whose id is N` instead of `message id N`.
    ///
    /// Issue #50 / #145: `id` is interpolated unquoted into `whose id is`. A
    /// release-safe numeric guard rejects non-numeric `id` — `Int(id)` succeeds
    /// only for `[+-]?\d+`; on failure an impossible id (-1) is substituted so the
    /// malicious string is never interpolated and the script fails cleanly with
    /// -1728. Server.swift's `requireMessageId` remains the user-facing contract.
    /// `internal` (not `private`) purely as the #145 test seam.
    func msgRef(_ id: String, mailbox: String, account: String, accountId: String? = nil) -> String {
        // #180: delegate to the resolveMsgRef chokepoint (was an inline build via
        // the legacy mailboxRef). Byte-identical for non-nested names at
        // accountId: nil (same #118 safeId guard, applied inside resolveMsgRef);
        // inherits #174 nested chains + #101/#176 UUID disambiguation when
        // accountId is provided.
        return resolveMsgRef(id: id, mailbox: mailbox, accountId: accountId, accountName: account)
    }
}

// MARK: - Mail Error

enum MailError: LocalizedError {
    case scriptCreationFailed
    case scriptFailed(message: String, code: Int)
    case invalidParameter(String)
    /// A handler-level failure whose `errorDescription` is the message verbatim
    /// — used when a raw AppleScript error (e.g. `-10000`) has been re-wrapped
    /// with an actionable, recovery-oriented explanation for the caller (#103).
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptCreationFailed:
            return "Failed to create AppleScript"
        case .scriptFailed(let message, let code):
            return "AppleScript error (\(code)): \(message)"
        case .invalidParameter(let message):
            return "Invalid parameter: \(message)"
        case .operationFailed(let message):
            return message
        }
    }
}
