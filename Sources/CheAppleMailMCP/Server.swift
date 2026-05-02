import Foundation
import MCP
import MailSQLite

/// MCP Server for Apple Mail
class CheAppleMailMCPServer {
    private let server: Server
    private let transport: StdioTransport
    private let mailController = MailController.shared
    private let tools: [Tool]
    private let indexReader: EnvelopeIndexReader?

    init() async throws {
        self.tools = Self.defineTools()
        self.server = Server(
            name: "che-apple-mail-mcp",
            version: "2.5.0",
            capabilities: .init(tools: .init())
        )
        self.transport = StdioTransport()

        // Initialize SQLite reader (optional — falls back to AppleScript if unavailable)
        // Only open the DB connection here; account mapping is built lazily on first search
        // to avoid blocking server startup with AppleScript calls.
        do {
            self.indexReader = try EnvelopeIndexReader(databasePath: EnvelopeIndexReader.defaultDatabasePath)
        } catch {
            self.indexReader = nil
        }

        await registerHandlers()

        // Fire-and-forget: trigger Mail.app sync so Envelope Index is fresh.
        // If Mail.app isn't running, this starts it. IDLE/fetch takes over after.
        Task { try? await mailController.checkForNewMail() }
    }

    func run() async throws {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Tool Definitions

    static func defineTools() -> [Tool] {
        [
            // Account Tools
            Tool(
                name: "list_accounts",
                description: "List all mail accounts configured in Apple Mail",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "get_account_info",
                description: "Get detailed information about a specific mail account",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "account_name": .object(["type": .string("string"), "description": .string("The name of the mail account")])
                    ]),
                    "required": .array([.string("account_name")])
                ])
            ),

            // Mailbox Tools
            Tool(
                name: "list_mailboxes",
                description: "List all mailboxes (folders) for an account",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "account_name": .object(["type": .string("string"), "description": .string("The name of the mail account (optional, lists all if omitted)")])
                    ])
                ])
            ),
            Tool(
                name: "create_mailbox",
                description: "Create a new mailbox (folder) in an account",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Name of the new mailbox")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The account to create the mailbox in")])
                    ]),
                    "required": .array([.string("name"), .string("account_name")])
                ])
            ),
            Tool(
                name: "delete_mailbox",
                description: "Delete a mailbox (folder) from an account",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Name of the mailbox to delete")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The account containing the mailbox")])
                    ]),
                    "required": .array([.string("name"), .string("account_name")])
                ])
            ),

            // Email Reading Tools
            Tool(
                name: "list_emails",
                description: "List emails in a mailbox",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name (e.g., 'INBOX')")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "limit": .object(["type": .string("integer"), "description": .string("Maximum number of emails to return (default: 50)")])
                    ]),
                    "required": .array([.string("mailbox"), .string("account_name")])
                ])
            ),
            Tool(
                name: "get_email",
                description: "Get full content of a specific email. Returns HTML by default (preserving links), or plain text/raw source with format parameter.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "format": .object(["type": .string("string"), "description": .string("Content format: 'html' (default, preserves links), 'text' (plain text), 'source' (full MIME)")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name")])
                ])
            ),
            Tool(
                name: "search_emails",
                description: "Search emails across ALL accounts and mailboxes using fast SQLite index (millisecond speed on 250K+ emails). Supports searching by subject, sender, recipient, or all fields. Results include account_name and mailbox so you know where each email was found.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string"), "description": .string("Search query string")]),
                        "field": .object(["type": .string("string"), "description": .string("Search field: 'subject', 'sender', 'recipient', or 'any' (default: 'any' — searches all fields)")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox to search in (optional — omit to search all mailboxes)")]),
                        "account_name": .object(["type": .string("string"), "description": .string("Mail account (optional — omit to search all accounts)")]),
                        "date_from": .object(["type": .string("string"), "description": .string("Start date filter, ISO 8601 (e.g., '2026-01-01')")]),
                        "date_to": .object(["type": .string("string"), "description": .string("End date filter, ISO 8601 (e.g., '2026-03-31')")]),
                        "limit": .object(["type": .string("integer"), "description": .string("Maximum results (default: 50)")]),
                        "sort": .object(["type": .string("string"), "description": .string("Sort order by date: 'desc' (newest first, default) or 'asc' (oldest first)")])
                    ]),
                    "required": .array([.string("query")])
                ])
            ),
            Tool(
                name: "get_unread_count",
                description: "Get the number of unread emails",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name (optional)")]),
                        "account_name": .object(["type": .string("string"), "description": .string("Account name (optional)")])
                    ])
                ])
            ),

            // Email Action Tools
            Tool(
                name: "mark_read",
                description: "Mark an email as read or unread",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "read": .object(["type": .string("boolean"), "description": .string("true=read, false=unread")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("read")])
                ])
            ),
            Tool(
                name: "flag_email",
                description: "Flag or unflag an email",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "flagged": .object(["type": .string("boolean"), "description": .string("true=flag, false=unflag")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("flagged")])
                ])
            ),
            Tool(
                name: "move_email",
                description: "Move an email to another mailbox",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "from_mailbox": .object(["type": .string("string"), "description": .string("Source mailbox")]),
                        "to_mailbox": .object(["type": .string("string"), "description": .string("Destination mailbox")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")])
                    ]),
                    "required": .array([.string("id"), .string("from_mailbox"), .string("to_mailbox"), .string("account_name")])
                ])
            ),
            Tool(
                name: "delete_email",
                description: "Delete an email (move to trash)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name")])
                ])
            ),

            // Compose Tools
            Tool(
                name: "compose_email",
                description: "Compose and send a new email. Body formatting is controlled by the 'format' parameter (default: 'plain'; use 'markdown' or 'html' for rich text).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "to": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Recipient email addresses")]),
                        "subject": .object(["type": .string("string"), "description": .string("Email subject")]),
                        "body": .object(["type": .string("string"), "description": .string("Email body content (interpreted according to 'format')")]),
                        "cc": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("CC recipients (optional)")]),
                        "bcc": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("BCC recipients (optional)")]),
                        "attachments": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Absolute file paths to attach (optional)")]),
                        "format": .object(["type": .string("string"), "enum": .array([.string("plain"), .string("markdown"), .string("html")]), "description": .string("Body format. 'plain' (default) passes body as-is; 'markdown' renders bold/italic/code/links/lists; 'html' inserts raw HTML.")])
                    ]),
                    "required": .array([.string("to"), .string("subject"), .string("body")])
                ])
            ),
            Tool(
                name: "reply_email",
                description: "Reply to an email. Body formatting is controlled by the 'format' parameter (default: 'plain'; use 'markdown' or 'html' for rich text). 'plain' embeds the original message as RFC 3676 `> `-prefixed quoted lines; 'markdown'/'html' wrap the original in a `<blockquote>`. Optionally add extra CC, attach files, and save as draft instead of sending.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID to reply to")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "body": .object(["type": .string("string"), "description": .string("Reply content (interpreted according to 'format')")]),
                        "reply_all": .object(["type": .string("boolean"), "description": .string("Reply to all recipients (default: false)")]),
                        "cc_additional": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Extra CC recipients to add on top of those derived from 'reply_all'. Email addresses (RFC 5322 addr-spec).")]),
                        "attachments": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Absolute file paths to attach to the reply.")]),
                        "save_as_draft": .object(["type": .string("boolean"), "description": .string("If true, save the reply as a draft instead of sending it (default: false). Use when you want a human to review before send.")]),
                        "format": .object(["type": .string("string"), "enum": .array([.string("plain"), .string("markdown"), .string("html")]), "description": .string("Body format. 'plain' (default) prepends the user body to the original message quoted with RFC 3676 `> ` line prefix; 'markdown'/'html' produce rich text and wrap the original in a `<blockquote>`.")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("body")])
                ])
            ),
            Tool(
                name: "forward_email",
                description: "Forward an email. Body formatting is controlled by the 'format' parameter (default: 'plain'; use 'markdown' or 'html' for rich text). Non-plain modes wrap the original message in a blockquote.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID to forward")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "to": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Recipients to forward to")]),
                        "body": .object(["type": .string("string"), "description": .string("Optional message to add (interpreted according to 'format')")]),
                        "format": .object(["type": .string("string"), "enum": .array([.string("plain"), .string("markdown"), .string("html")]), "description": .string("Body format. 'plain' (default), 'markdown', or 'html'.")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("to")])
                ])
            ),

            // Draft Tools
            Tool(
                name: "list_drafts",
                description: "List all draft emails",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")])
                    ]),
                    "required": .array([.string("account_name")])
                ])
            ),
            Tool(
                name: "create_draft",
                description: "Create a new draft email. Body formatting is controlled by the 'format' parameter (default: 'plain'; use 'markdown' or 'html' for rich text).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "to": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Recipient email addresses")]),
                        "subject": .object(["type": .string("string"), "description": .string("Email subject")]),
                        "body": .object(["type": .string("string"), "description": .string("Email body content (interpreted according to 'format')")]),
                        "attachments": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Absolute file paths to attach (optional)")]),
                        "format": .object(["type": .string("string"), "enum": .array([.string("plain"), .string("markdown"), .string("html")]), "description": .string("Body format. 'plain' (default) passes body as-is; 'markdown' renders bold/italic/code/links/lists; 'html' inserts raw HTML.")])
                    ]),
                    "required": .array([.string("to"), .string("subject"), .string("body")])
                ])
            ),

            // Attachment Tools
            Tool(
                name: "list_attachments",
                description: "List attachments of an email",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name")])
                ])
            ),
            Tool(
                name: "save_attachment",
                description: "Save an email attachment to disk",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "attachment_name": .object(["type": .string("string"), "description": .string("Name of the attachment to save")]),
                        "save_path": .object(["type": .string("string"), "description": .string("Full path where to save the file")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("attachment_name"), .string("save_path")])
                ])
            ),

            // VIP Tools
            Tool(
                name: "list_vip_senders",
                description: "List VIP senders",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),

            // Rule Tools
            Tool(
                name: "list_rules",
                description: "List all mail rules",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "enable_rule",
                description: "Enable or disable a mail rule",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Name of the rule")]),
                        "enabled": .object(["type": .string("boolean"), "description": .string("true=enable, false=disable")])
                    ]),
                    "required": .array([.string("name"), .string("enabled")])
                ])
            ),
            Tool(
                name: "get_rule_details",
                description: "Get detailed information about a mail rule",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Name of the rule")])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),
            Tool(
                name: "create_rule",
                description: "Create a new mail rule",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Name of the rule")]),
                        "conditions": .object(["type": .string("array"), "description": .string("Array of conditions with header, qualifier, expression")]),
                        "actions": .object(["type": .string("object"), "description": .string("Actions: move_message, mark_read, mark_flagged, delete_message")])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),
            Tool(
                name: "delete_rule",
                description: "Delete a mail rule",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Name of the rule to delete")])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),

            // Mail Check & Sync Tools
            Tool(
                name: "check_for_new_mail",
                description: "Trigger a check for new email",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "account_name": .object(["type": .string("string"), "description": .string("Account to check (optional, checks all if omitted)")])
                    ])
                ])
            ),
            Tool(
                name: "synchronize_account",
                description: "Synchronize an IMAP account with the server",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "account_name": .object(["type": .string("string"), "description": .string("Account to synchronize")])
                    ]),
                    "required": .array([.string("account_name")])
                ])
            ),

            // Advanced Email Tools
            Tool(
                name: "copy_email",
                description: "Copy an email to another mailbox",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "from_mailbox": .object(["type": .string("string"), "description": .string("Source mailbox")]),
                        "to_mailbox": .object(["type": .string("string"), "description": .string("Destination mailbox")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")])
                    ]),
                    "required": .array([.string("id"), .string("from_mailbox"), .string("to_mailbox"), .string("account_name")])
                ])
            ),
            Tool(
                name: "set_flag_color",
                description: "Set the flag color of an email (0=red, 1=orange, 2=yellow, 3=green, 4=blue, 5=purple, 6=gray, -1=clear)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "color_index": .object(["type": .string("integer"), "description": .string("Flag color index (0-6, or -1 to clear)")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("color_index")])
                ])
            ),
            Tool(
                name: "set_background_color",
                description: "Set the background color of an email (blue, gray, green, none, orange, purple, red, yellow)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "color": .object(["type": .string("string"), "description": .string("Background color: blue, gray, green, none, orange, purple, red, yellow")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("color")])
                ])
            ),
            Tool(
                name: "mark_as_junk",
                description: "Mark an email as junk or not junk",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "is_junk": .object(["type": .string("boolean"), "description": .string("true=junk, false=not junk")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("is_junk")])
                ])
            ),
            Tool(
                name: "get_email_headers",
                description: "Get all headers of an email",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name")])
                ])
            ),
            Tool(
                name: "get_email_source",
                description: "Get the raw source of an email",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name")])
                ])
            ),
            Tool(
                name: "redirect_email",
                description: "Redirect an email (keeps original sender, different from forward)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")]),
                        "to": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Recipients to redirect to")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name"), .string("to")])
                ])
            ),
            Tool(
                name: "get_email_metadata",
                description: "Get email metadata (was forwarded, replied, redirected, size)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                        "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                        "account_name": .object(["type": .string("string"), "description": .string("The mail account")])
                    ]),
                    "required": .array([.string("id"), .string("mailbox"), .string("account_name")])
                ])
            ),

            // Signature Tools
            Tool(
                name: "list_signatures",
                description: "List all email signatures",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "get_signature",
                description: "Get the content of a signature",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Name of the signature")])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),

            // SMTP Server Tools
            Tool(
                name: "list_smtp_servers",
                description: "List all SMTP servers",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),

            // Special Mailboxes
            Tool(
                name: "get_special_mailboxes",
                description: "Get special mailbox names (inbox, drafts, sent, trash, junk, outbox)",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),

            // Address Tools
            Tool(
                name: "extract_name_from_address",
                description: "Extract the name from a full email address (e.g., 'John Doe <john@example.com>' -> 'John Doe')",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "address": .object(["type": .string("string"), "description": .string("Full email address")])
                    ]),
                    "required": .array([.string("address")])
                ])
            ),
            Tool(
                name: "extract_address",
                description: "Extract the email address from a full address string (e.g., 'John Doe <john@example.com>' -> 'john@example.com')",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "address": .object(["type": .string("string"), "description": .string("Full email address")])
                    ]),
                    "required": .array([.string("address")])
                ])
            ),

            // Application Tools
            Tool(
                name: "get_mail_app_info",
                description: "Get Mail application information (version, fetch interval, background activity)",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            Tool(
                name: "open_mailto",
                description: "Open a mailto URL to compose an email",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "url": .object(["type": .string("string"), "description": .string("mailto URL (e.g., 'mailto:test@example.com?subject=Hello')")])
                    ]),
                    "required": .array([.string("url")])
                ])
            ),

            // Import Tools
            Tool(
                name: "import_mailbox",
                description: "Import a mailbox from a file",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string"), "description": .string("Path to the mailbox file to import")])
                    ]),
                    "required": .array([.string("path")])
                ])
            ),

            // Batch Tools
            Tool(
                name: "get_emails_batch",
                description: "Get full content of multiple emails in a single call. Much faster than calling get_email repeatedly. Returns results for each email, including errors for any that failed.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "emails": .object([
                            "type": .string("array"),
                            "description": .string("Array of email identifiers"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                                    "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                                    "account_name": .object(["type": .string("string"), "description": .string("The mail account")])
                                ]),
                                "required": .array([.string("id"), .string("mailbox"), .string("account_name")])
                            ])
                        ]),
                        "format": .object(["type": .string("string"), "description": .string("Content format: 'html' (default), 'text', 'source'")])
                    ]),
                    "required": .array([.string("emails")])
                ])
            ),
            Tool(
                name: "list_attachments_batch",
                description: "List attachments for multiple emails in a single call. Returns attachment lists for each email, including errors for any that failed.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "emails": .object([
                            "type": .string("array"),
                            "description": .string("Array of email identifiers"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "id": .object(["type": .string("string"), "description": .string("The email ID")]),
                                    "mailbox": .object(["type": .string("string"), "description": .string("Mailbox name")]),
                                    "account_name": .object(["type": .string("string"), "description": .string("The mail account")])
                                ]),
                                "required": .array([.string("id"), .string("mailbox"), .string("account_name")])
                            ])
                        ])
                    ]),
                    "required": .array([.string("emails")])
                ])
            ),
        ]
    }

    // MARK: - Handler Registration

    private func registerHandlers() async {
        await server.withMethodHandler(ListTools.self) { [tools] _ in
            ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self = self else {
                return CallTool.Result(content: [.text("Server unavailable")], isError: true)
            }
            return await self.handleToolCall(name: params.name, arguments: params.arguments ?? [:])
        }
    }

    // MARK: - Tool Call Handler

    private func handleToolCall(name: String, arguments: [String: Value]) async -> CallTool.Result {
        do {
            let result = try await executeToolCall(name: name, arguments: arguments)
            return CallTool.Result(content: [.text(result)])
        } catch {
            return CallTool.Result(content: [.text("Error: \(error.localizedDescription)")], isError: true)
        }
    }

    private func executeToolCall(name: String, arguments: [String: Value]) async throws -> String {
        switch name {
        // Account Tools
        case "list_accounts":
            // Primary: AppleScript path — only way to resolve EWS display_name
            // (AccountsMap.plist has no email field, so SQLite/filesystem
            // fallback cannot recover the email for Exchange accounts).
            // See #11 for the full analysis.
            do {
                let accounts = try await mailController.listAccounts()
                return formatJSON(accounts)
            } catch {
                // Fallback: SQLite path, only if AppleScript fails (e.g., Mail.app
                // not running). Returns the same JSON schema but with empty
                // user_name / email_addresses for EWS accounts.
                if let reader = indexReader {
                    return formatJSON(reader.listAccounts())
                }
                throw error
            }

        case "get_account_info":
            guard let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("account_name is required")
            }
            if let reader = indexReader {
                let accounts = reader.listAccounts()
                if let acct = accounts.first(where: { ($0["name"] as? String) == accountName }) {
                    return formatJSON(acct)
                }
            }
            let info = try await mailController.getAccountInfo(accountName: accountName)
            return formatJSON(info)

        // Mailbox Tools
        case "list_mailboxes":
            let accountName = arguments["account_name"]?.stringValue
            if let reader = indexReader {
                let mailboxes = try reader.listMailboxes(accountName: accountName)
                return formatJSON(mailboxes)
            }
            let mailboxes = try await mailController.listMailboxes(accountName: accountName)
            return formatJSON(mailboxes)

        case "create_mailbox":
            guard let name = arguments["name"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("name and account_name are required")
            }
            return try await mailController.createMailbox(name: name, accountName: accountName)

        case "delete_mailbox":
            guard let name = arguments["name"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("name and account_name are required")
            }
            return try await mailController.deleteMailbox(name: name, accountName: accountName)

        // Email Reading Tools
        case "list_emails":
            guard let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("mailbox and account_name are required")
            }
            let limit = arguments["limit"]?.intValue ?? 50
            if let reader = indexReader {
                let emails = try reader.listEmails(mailbox: mailbox, accountName: accountName, limit: limit)
                return formatJSON(emails)
            }
            let emails = try await mailController.listEmails(mailbox: mailbox, accountName: accountName, limit: limit)
            return formatJSON(emails)

        case "get_email":
            guard let id = arguments["id"]?.stringValue,
                  let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("id, mailbox, and account_name are required")
            }
            let format = arguments["format"]?.stringValue ?? "html"
            // Try SQLite/emlx first, fall back to AppleScript

            if let reader = indexReader, let rowId = Int(id) {
                do {
                    if let mailboxUrl = try reader.mailboxURL(forMessageId: rowId) {
                        let content = try EmlxParser.readEmail(rowId: rowId, mailboxURL: mailboxUrl, format: format)
                        var result: [String: Any] = [
                            "id": id,
                            "subject": content.subject,
                            "sender": content.sender,
                            "date": content.date,
                            "to": content.toRecipients,
                            "cc": content.ccRecipients,
                            "message_id": content.messageId
                        ]
                        if let text = content.textBody { result["text_body"] = text }
                        if let html = content.htmlBody { result["html_body"] = html }
                        if let source = content.rawSource { result["source"] = String(data: source, encoding: .utf8) ?? "" }
                        return formatJSON(result)
                    }
                } catch {
                    // Fall through to AppleScript
                }
            }
            let email = try await mailController.getEmail(id: id, mailbox: mailbox, accountName: accountName, format: format)
            return formatJSON(email)

        case "search_emails":
            guard let query = arguments["query"]?.stringValue else {
                throw MailError.invalidParameter("query is required")
            }
            let mailbox = arguments["mailbox"]?.stringValue
            let accountName = arguments["account_name"]?.stringValue
            let limit = arguments["limit"]?.intValue ?? 50
            let sort = arguments["sort"]?.stringValue ?? "desc"
            let fieldStr = arguments["field"]?.stringValue ?? "any"
            let dateFromStr = arguments["date_from"]?.stringValue
            let dateToStr = arguments["date_to"]?.stringValue
            // Use SQLite search if available

            if let reader = indexReader {
                let field = SearchField(rawValue: fieldStr) ?? .any
                let sortOrder = SortOrder(rawValue: sort) ?? .desc
                let dateFrom = dateFromStr.flatMap { Self.parseDate($0) }
                let dateTo = dateToStr.flatMap { Self.parseDate($0) }
                let params = SearchParameters(
                    query: query, field: field, accountName: accountName,
                    mailbox: mailbox, dateFrom: dateFrom, dateTo: dateTo,
                    sort: sortOrder, limit: limit
                )
                let results = try reader.search(params)
                let formatted: [[String: Any]] = results.map { r in
                    [
                        "id": String(r.id),
                        "subject": r.subject,
                        "sender": r.senderAddress.isEmpty ? r.senderName : "\(r.senderName) <\(r.senderAddress)>",
                        "date_received": ISO8601DateFormatter().string(from: r.dateReceived),
                        "account_name": r.accountName,
                        "mailbox": r.mailboxPath,
                        "to": r.toRecipients
                    ]
                }
                return formatJSON(formatted)
            }
            // Fallback to AppleScript
            let results = try await mailController.searchEmails(query: query, mailbox: mailbox, accountName: accountName, limit: limit, sort: sort)
            return formatJSON(results)

        case "get_unread_count":
            let mailbox = arguments["mailbox"]?.stringValue
            let accountName = arguments["account_name"]?.stringValue
            if let reader = indexReader {
                let count = try reader.getUnreadCount(mailbox: mailbox, accountName: accountName)
                return "Unread count: \(count)"
            }
            let count = try await mailController.getUnreadCount(mailbox: mailbox, accountName: accountName)
            return "Unread count: \(count)"

        // Email Action Tools
        case "mark_read":
            guard let id = arguments["id"]?.stringValue,
                  let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let read = arguments["read"]?.boolValue else {
                throw MailError.invalidParameter("id, mailbox, account_name, and read are required")
            }
            return try await mailController.markRead(id: id, mailbox: mailbox, accountName: accountName, read: read)

        case "flag_email":
            guard let id = arguments["id"]?.stringValue,
                  let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let flagged = arguments["flagged"]?.boolValue else {
                throw MailError.invalidParameter("id, mailbox, account_name, and flagged are required")
            }
            return try await mailController.flagEmail(id: id, mailbox: mailbox, accountName: accountName, flagged: flagged)

        case "move_email":
            guard let id = arguments["id"]?.stringValue,
                  let fromMailbox = arguments["from_mailbox"]?.stringValue,
                  let toMailbox = arguments["to_mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("id, from_mailbox, to_mailbox, and account_name are required")
            }
            return try await mailController.moveEmail(id: id, fromMailbox: fromMailbox, toMailbox: toMailbox, accountName: accountName)

        case "delete_email":
            guard let id = arguments["id"]?.stringValue,
                  let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("id, mailbox, and account_name are required")
            }
            return try await mailController.deleteEmail(id: id, mailbox: mailbox, accountName: accountName)

        // Compose Tools
        case "compose_email":
            guard let toArray = arguments["to"]?.arrayValue,
                  let subject = arguments["subject"]?.stringValue,
                  let body = arguments["body"]?.stringValue else {
                throw MailError.invalidParameter("to, subject, and body are required")
            }
            let to = toArray.compactMap { $0.stringValue }
            let cc = arguments["cc"]?.arrayValue?.compactMap { $0.stringValue }
            let bcc = arguments["bcc"]?.arrayValue?.compactMap { $0.stringValue }
            let attachments = arguments["attachments"]?.arrayValue?.compactMap { $0.stringValue }
            let format = try parseBodyFormatArgument(arguments["format"])
            return try await mailController.composeEmail(to: to, subject: subject, body: body, cc: cc, bcc: bcc, attachments: attachments, format: format)

        case "reply_email":
            guard let id = arguments["id"]?.stringValue,
                  let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let body = arguments["body"]?.stringValue else {
                throw MailError.invalidParameter("id, mailbox, account_name, and body are required")
            }
            let replyAll = arguments["reply_all"]?.boolValue ?? false
            let ccAdditional = arguments["cc_additional"]?.arrayValue?.compactMap { $0.stringValue }
            let replyAttachments = arguments["attachments"]?.arrayValue?.compactMap { $0.stringValue }
            let saveAsDraft = arguments["save_as_draft"]?.boolValue ?? false
            let format = try parseBodyFormatArgument(arguments["format"])
            return try await mailController.replyEmail(id: id, mailbox: mailbox, accountName: accountName, body: body, replyAll: replyAll, ccAdditional: ccAdditional, attachments: replyAttachments, saveAsDraft: saveAsDraft, format: format)

        case "forward_email":
            guard let id = arguments["id"]?.stringValue,
                  let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let toArray = arguments["to"]?.arrayValue else {
                throw MailError.invalidParameter("id, mailbox, account_name, and to are required")
            }
            let to = toArray.compactMap { $0.stringValue }
            let body = arguments["body"]?.stringValue
            let format = try parseBodyFormatArgument(arguments["format"])
            return try await mailController.forwardEmail(id: id, mailbox: mailbox, accountName: accountName, to: to, body: body, format: format)

        // Draft Tools
        case "list_drafts":
            guard let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("account_name is required")
            }
            let drafts = try await mailController.listDrafts(accountName: accountName)
            return formatJSON(drafts)

        case "create_draft":
            guard let toArray = arguments["to"]?.arrayValue,
                  let subject = arguments["subject"]?.stringValue,
                  let body = arguments["body"]?.stringValue else {
                throw MailError.invalidParameter("to, subject, and body are required")
            }
            let to = toArray.compactMap { $0.stringValue }
            let attachments = arguments["attachments"]?.arrayValue?.compactMap { $0.stringValue }
            let format = try parseBodyFormatArgument(arguments["format"])
            return try await mailController.createDraft(to: to, subject: subject, body: body, attachments: attachments, format: format)

        // Attachment Tools
        case "list_attachments":
            guard let id = arguments["id"]?.stringValue,
                  let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("id, mailbox, and account_name are required")
            }
            if let reader = indexReader, let rowId = Int(id) {
                let sqliteAttachments = try reader.listAttachments(messageId: rowId)
                // Cross-validate SQLite metadata against actual .emlx contents
                // (issue #24): SQLite caches attachment rows even after Mail.app
                // strips the binary on Sent / IMAP lazy-load, leaving stale
                // entries that save_attachment then fails to extract. Filter
                // SQLite results to names actually present in the .emlx body.
                if let mailboxUrl = try reader.mailboxURL(forMessageId: rowId) {
                    do {
                        let realNames = try EmlxParser.attachmentNames(
                            rowId: rowId,
                            mailboxURL: mailboxUrl
                        )
                        let validated = sqliteAttachments.filter { entry in
                            guard let name = entry["name"] as? String else { return false }
                            return realNames.contains(name)
                        }
                        return formatJSON(validated)
                    } catch {
                        // .emlx unreadable / parse failed — log and fall back
                        // to raw SQLite metadata (matches save_attachment's
                        // fallback pattern). Caller may still hit the same
                        // not-found error on save, but we don't degrade the
                        // pre-#24 behavior for callers whose .emlx layer is
                        // genuinely broken.
                        let message = "list_attachments emlx validation failed for "
                            + "rowId=\(rowId): \(error.localizedDescription); "
                            + "returning unvalidated SQLite metadata\n"
                        FileHandle.standardError.write(Data(message.utf8))
                    }
                }
                return formatJSON(sqliteAttachments)
            }
            let attachments = try await mailController.listAttachments(id: id, mailbox: mailbox, accountName: accountName)
            return formatJSON(attachments)

        case "save_attachment":
            guard let id = arguments["id"]?.stringValue,
                  let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let attachmentName = arguments["attachment_name"]?.stringValue,
                  let savePath = arguments["save_path"]?.stringValue else {
                throw MailError.invalidParameter("id, mailbox, account_name, attachment_name, and save_path are required")
            }
            // Tier 1: SQLite + .emlx fast path (see openspec/changes/save-attachment-fast-path).
            // Wraps in its own do/catch so any failure falls through to the
            // AppleScript tier in the trailing `mailController.saveAttachment`
            // call — matches the two-tier pattern used by get_email (#9's
            // lesson: never collapse the tiers into one catch).
            if let reader = indexReader, let rowId = Int(id) {
                do {
                    if let mailboxUrl = try reader.mailboxURL(forMessageId: rowId) {
                        let destination = URL(fileURLWithPath: savePath)
                        try EmlxParser.saveAttachment(
                            rowId: rowId,
                            mailboxURL: mailboxUrl,
                            attachmentName: attachmentName,
                            destination: destination
                        )
                        return "Attachment saved to \(savePath)"
                    }
                } catch {
                    // Log the cause so silent fallbacks are observable,
                    // then fall through to the AppleScript fallback below.
                    let message = "SQLite save_attachment fast path failed: "
                        + "\(error.localizedDescription), "
                        + "falling through to AppleScript\n"
                    FileHandle.standardError.write(Data(message.utf8))
                }
            }
            // Tier 2: AppleScript fallback (legacy path, preserved unchanged).
            return try await mailController.saveAttachment(id: id, mailbox: mailbox, accountName: accountName, attachmentName: attachmentName, savePath: savePath)

        // VIP Tools
        case "list_vip_senders":
            if let reader = indexReader {
                let vips = reader.listVIPSenders()
                return formatJSON(vips)
            }
            let vips = try await mailController.listVIPSenders()
            return formatJSON(vips)

        // Rule Tools
        case "list_rules":
            let rules = try await mailController.listRules()
            return formatJSON(rules)

        case "enable_rule":
            guard let name = arguments["name"]?.stringValue,
                  let enabled = arguments["enabled"]?.boolValue else {
                throw MailError.invalidParameter("name and enabled are required")
            }
            return try await mailController.enableRule(name: name, enabled: enabled)

        case "get_rule_details":
            guard let name = arguments["name"]?.stringValue else {
                throw MailError.invalidParameter("name is required")
            }
            let details = try await mailController.getRuleDetails(name: name)
            return formatJSON(details)

        case "create_rule":
            guard let name = arguments["name"]?.stringValue else {
                throw MailError.invalidParameter("name is required")
            }
            let conditions = arguments["conditions"]?.arrayValue?.compactMap { value -> [String: String]? in
                guard let obj = value.objectValue else { return nil }
                var dict: [String: String] = [:]
                for (k, v) in obj {
                    if let str = v.stringValue {
                        dict[k] = str
                    }
                }
                return dict
            } ?? []
            let actions = arguments["actions"]?.objectValue?.reduce(into: [String: Any]()) { result, pair in
                if let str = pair.value.stringValue {
                    result[pair.key] = str
                } else if let bool = pair.value.boolValue {
                    result[pair.key] = bool
                }
            } ?? [:]
            return try await mailController.createRule(name: name, conditions: conditions, actions: actions)

        case "delete_rule":
            guard let name = arguments["name"]?.stringValue else {
                throw MailError.invalidParameter("name is required")
            }
            return try await mailController.deleteRule(name: name)

        // Mail Check & Sync Tools
        case "check_for_new_mail":
            let accountName = arguments["account_name"]?.stringValue
            return try await mailController.checkForNewMail(accountName: accountName)

        case "synchronize_account":
            guard let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("account_name is required")
            }
            return try await mailController.synchronizeAccount(accountName: accountName)

        // Advanced Email Tools
        case "copy_email":
            guard let id = arguments["id"]?.stringValue,
                  let fromMailbox = arguments["from_mailbox"]?.stringValue,
                  let toMailbox = arguments["to_mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("id, from_mailbox, to_mailbox, and account_name are required")
            }
            return try await mailController.copyEmail(id: id, fromMailbox: fromMailbox, toMailbox: toMailbox, accountName: accountName)

        case "set_flag_color":
            guard let id = arguments["id"]?.stringValue,
                  let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let colorIndex = arguments["color_index"]?.intValue else {
                throw MailError.invalidParameter("id, mailbox, account_name, and color_index are required")
            }
            return try await mailController.setFlagColor(id: id, mailbox: mailbox, accountName: accountName, colorIndex: colorIndex)

        case "set_background_color":
            guard let id = arguments["id"]?.stringValue,
                  let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let color = arguments["color"]?.stringValue else {
                throw MailError.invalidParameter("id, mailbox, account_name, and color are required")
            }
            return try await mailController.setBackgroundColor(id: id, mailbox: mailbox, accountName: accountName, color: color)

        case "mark_as_junk":
            guard let id = arguments["id"]?.stringValue,
                  let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let isJunk = arguments["is_junk"]?.boolValue else {
                throw MailError.invalidParameter("id, mailbox, account_name, and is_junk are required")
            }
            return try await mailController.markAsJunk(id: id, mailbox: mailbox, accountName: accountName, isJunk: isJunk)

        case "get_email_headers":
            guard let id = arguments["id"]?.stringValue,
                  let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("id, mailbox, and account_name are required")
            }
            if let reader = indexReader, let rowId = Int(id),
               let mailboxUrl = try? reader.mailboxURL(forMessageId: rowId) {
                if let headers = try? EmlxParser.readHeaders(rowId: rowId, mailboxURL: mailboxUrl) {
                    return headers
                }
            }
            return try await mailController.getEmailHeaders(id: id, mailbox: mailbox, accountName: accountName)

        case "get_email_source":
            guard let id = arguments["id"]?.stringValue,
                  let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("id, mailbox, and account_name are required")
            }
            if let reader = indexReader, let rowId = Int(id),
               let mailboxUrl = try? reader.mailboxURL(forMessageId: rowId) {
                if let source = try? EmlxParser.readSource(rowId: rowId, mailboxURL: mailboxUrl) {
                    return source
                }
            }
            return try await mailController.getEmailSource(id: id, mailbox: mailbox, accountName: accountName)

        case "redirect_email":
            guard let id = arguments["id"]?.stringValue,
                  let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue,
                  let toArray = arguments["to"]?.arrayValue else {
                throw MailError.invalidParameter("id, mailbox, account_name, and to are required")
            }
            let to = toArray.compactMap { $0.stringValue }
            return try await mailController.redirectEmail(id: id, mailbox: mailbox, accountName: accountName, to: to)

        case "get_email_metadata":
            guard let id = arguments["id"]?.stringValue,
                  let mailbox = arguments["mailbox"]?.stringValue,
                  let accountName = arguments["account_name"]?.stringValue else {
                throw MailError.invalidParameter("id, mailbox, and account_name are required")
            }
            if let reader = indexReader, let rowId = Int(id) {
                let metadata = try reader.getEmailMetadata(messageId: rowId)
                return formatJSON(metadata)
            }
            let metadata = try await mailController.getEmailMetadata(id: id, mailbox: mailbox, accountName: accountName)
            return formatJSON(metadata)

        // Signature Tools
        case "list_signatures":
            let signatures = try await mailController.listSignatures()
            return formatJSON(signatures)

        case "get_signature":
            guard let name = arguments["name"]?.stringValue else {
                throw MailError.invalidParameter("name is required")
            }
            let signature = try await mailController.getSignature(name: name)
            return formatJSON(signature)

        // SMTP Server Tools
        case "list_smtp_servers":
            let servers = try await mailController.listSMTPServers()
            return formatJSON(servers)

        // Special Mailboxes
        case "get_special_mailboxes":
            let mailboxes = try await mailController.getSpecialMailboxes()
            return formatJSON(mailboxes)

        // Address Tools
        case "extract_name_from_address":
            guard let address = arguments["address"]?.stringValue else {
                throw MailError.invalidParameter("address is required")
            }
            let name = try await mailController.extractNameFromAddress(address: address)
            return name

        case "extract_address":
            guard let address = arguments["address"]?.stringValue else {
                throw MailError.invalidParameter("address is required")
            }
            return try await mailController.extractAddressFrom(address: address)

        // Application Tools
        case "get_mail_app_info":
            let info = try await mailController.getMailAppInfo()
            return formatJSON(info)

        case "open_mailto":
            guard let url = arguments["url"]?.stringValue else {
                throw MailError.invalidParameter("url is required")
            }
            return try await mailController.openMailtoURL(url: url)

        // Import Tools
        case "import_mailbox":
            guard let path = arguments["path"]?.stringValue else {
                throw MailError.invalidParameter("path is required")
            }
            return try await mailController.importMailbox(path: path)

        // Batch Tools
        case "get_emails_batch":
            guard let emailsArray = arguments["emails"]?.arrayValue else {
                throw MailError.invalidParameter("emails array is required")
            }
            guard emailsArray.count <= 50 else {
                throw MailError.invalidParameter("Batch size exceeds maximum of 50 items")
            }
            let format = arguments["format"]?.stringValue ?? "html"
            var results: [[String: Any]] = []
            for emailVal in emailsArray {
                guard let obj = emailVal.objectValue,
                      let id = obj["id"]?.stringValue,
                      let mailbox = obj["mailbox"]?.stringValue,
                      let accountName = obj["account_name"]?.stringValue else {
                    results.append(["error": "Missing required fields (id, mailbox, account_name)"])
                    continue
                }
                // Try SQLite/emlx first; on any failure, fall through to
                // AppleScript — mirrors the structure of `get_email` so both
                // tools behave identically when the filesystem-fast-path is
                // unavailable. See #9.
                if let reader = indexReader, let rowId = Int(id) {
                    do {
                        if let mailboxUrl = try reader.mailboxURL(forMessageId: rowId) {
                            let content = try EmlxParser.readEmail(rowId: rowId, mailboxURL: mailboxUrl, format: format)
                            var entry: [String: Any] = [
                                "id": id, "subject": content.subject, "sender": content.sender,
                                "date": content.date, "to": content.toRecipients, "cc": content.ccRecipients
                            ]
                            if let text = content.textBody { entry["text_body"] = text }
                            if let html = content.htmlBody { entry["html_body"] = html }
                            if let source = content.rawSource { entry["source"] = String(data: source, encoding: .utf8) ?? "" }
                            results.append(entry)
                            continue
                        }
                    } catch {
                        // Fall through to AppleScript
                    }
                }
                // Fallback to AppleScript
                do {
                    let email = try await mailController.getEmail(id: id, mailbox: mailbox, accountName: accountName, format: format)
                    results.append(email)
                } catch {
                    results.append(["id": id, "error": error.localizedDescription])
                }
            }
            return formatJSON(results)

        case "list_attachments_batch":
            guard let emailsArray = arguments["emails"]?.arrayValue else {
                throw MailError.invalidParameter("emails array is required")
            }
            guard emailsArray.count <= 50 else {
                throw MailError.invalidParameter("Batch size exceeds maximum of 50 items")
            }
            var results: [[String: Any]] = []
            for emailVal in emailsArray {
                guard let obj = emailVal.objectValue,
                      let id = obj["id"]?.stringValue,
                      let mailbox = obj["mailbox"]?.stringValue,
                      let accountName = obj["account_name"]?.stringValue else {
                    results.append(["error": "Missing required fields (id, mailbox, account_name)"])
                    continue
                }
                do {
                    let attachments = try await mailController.listAttachments(id: id, mailbox: mailbox, accountName: accountName)
                    results.append(["id": id, "mailbox": mailbox, "account_name": accountName, "attachments": attachments])
                } catch {
                    results.append(["id": id, "error": error.localizedDescription])
                }
            }
            return formatJSON(results)

        default:
            throw MailError.invalidParameter("Unknown tool: \(name)")
        }
    }

    // MARK: - Helpers

    private static func parseDate(_ string: String) -> Date? {
        // Try ISO 8601 with time
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: string) { return date }
        // Try date-only (YYYY-MM-DD) in local timezone
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = .current
        return dateFormatter.date(from: string)
    }

    private func formatJSON(_ value: Any) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            return String(describing: value)
        }
    }
}

// MARK: - Value Extensions

extension Value {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        if case .string(let s) = self { return Int(s) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        if case .string(let s) = self { return s == "true" }
        return nil
    }

    var arrayValue: [Value]? {
        if case .array(let arr) = self { return arr }
        return nil
    }

    var objectValue: [String: Value]? {
        if case .object(let obj) = self { return obj }
        return nil
    }
}

func parseBodyFormat(_ raw: String?) throws -> BodyFormat {
    if let format = BodyFormat(rawValueOrNil: raw) {
        return format
    }
    throw MailError.invalidParameter("format must be one of: plain, markdown, html (got: \(raw ?? "nil"))")
}

func parseBodyFormatArgument(_ raw: Value?) throws -> BodyFormat {
    guard let raw = raw else { return .plain }
    if case .null = raw { return .plain }
    guard let str = raw.stringValue else {
        throw MailError.invalidParameter("format must be a string (plain, markdown, or html)")
    }
    return try parseBodyFormat(str)
}
