import MCP

/// What each tool does to mail, files and the outside world, as MCP annotations
/// (#601, #621).
///
/// A closed table, kept by name so the long `Tool(...)` bodies stay untouched.
/// Every tool is in exactly one class or annotates itself where it is defined
/// (the classification tools, `check_compose_length`); `ToolAccessTests` fails
/// on any other tool, so a new one cannot arrive without a decision.
///
/// The hints state facts about a tool. What a client does with them is the
/// client's policy. Annotations are static, so a tool with two modes declares
/// the worse one, and a tool that could sit in two classes takes the more
/// cautious.
enum ToolAccess: CaseIterable {
    /// Reads accounts, settings, rules or the server's own status, or parses its
    /// input. It returns the user's configuration, not message content, though
    /// a mailbox or rule name can quote other text.
    case readLocal
    /// Returns message content or metadata, which third parties wrote: open
    /// world, as `classify_emails` already is. `list_vip_senders` returns the
    /// senders of messages, and log text derives partly from mail content (a
    /// subject can land in it), so `get_mail_log_events` is here too. A read can
    /// make Mail fetch a body from the server (#274); that changes no mailbox.
    case readMail
    /// Creates something inside Mail and changes nothing that exists. A repeat
    /// adds another.
    case add
    /// Asks the mail server for new mail. A repeat fetches only what arrived since.
    case fetch
    /// Puts text the caller wrote where it can leave, and sends nothing: a draft
    /// syncs to the mail server and sits one key from sent, and `open_mailto`
    /// hands over to the system's default mail client, which may not be Mail.
    case prepareMail
    /// Modifies, moves or removes something that exists, sets a rule that will,
    /// or imports a mailbox, which is not undone in one step.
    case change
    /// `update_draft`: deletes the old draft, and the new one syncs like any draft.
    case replaceDraft
    /// Writes files on this machine and can replace one already there:
    /// `save_attachment` by design, an export through an attachment of the same
    /// name. Not idempotent, because a repeated export adds `-N` copies of its
    /// Markdown. `save_attachment` alone would be.
    case writeFile
    /// Can send mail. A sent message cannot be recalled, a retry sends a second
    /// one (#242), and mail leaves for third parties. `reply_email` also has a
    /// draft mode, but it can send.
    case send

    var annotations: Tool.Annotations {
        switch self {
        case .readLocal:
            return .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        case .readMail:
            return .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true)
        case .add:
            return .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        case .fetch:
            return .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true)
        case .prepareMail:
            return .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
        case .change, .writeFile:
            return .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
        case .replaceDraft, .send:
            return .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true)
        }
    }

    var toolNames: [String] {
        switch self {
        case .readLocal:
            return ["check_accessibility", "check_automation", "check_fda", "extract_address",
                    "extract_name_from_address", "get_account_info", "get_mail_app_info", "get_rule_details",
                    "get_signature", "get_special_mailboxes", "get_unread_count", "list_accounts",
                    "list_mailboxes", "list_rules", "list_signatures", "list_smtp_servers"]
        case .readMail:
            return ["get_email", "get_email_headers", "get_email_metadata", "get_email_source", "get_emails_batch",
                    "get_mail_log_events", "list_attachments", "list_attachments_batch", "list_drafts",
                    "list_emails", "list_vip_senders", "search_emails"]
        case .add:
            return ["copy_email", "create_mailbox"]
        case .fetch:
            return ["check_for_new_mail", "synchronize_account"]
        case .prepareMail:
            return ["create_draft", "open_mailto"]
        case .change:
            return ["create_rule", "delete_email", "delete_mailbox", "delete_rule", "enable_rule", "flag_email",
                    "import_mailbox", "mark_as_junk", "mark_read", "move_email", "set_background_color",
                    "set_flag_color"]
        case .replaceDraft:
            return ["update_draft"]
        case .writeFile:
            return ["save_attachment", "export_emails_markdown", "batch_export_emails_markdown"]
        case .send:
            return ["compose_email", "reply_email", "forward_email", "redirect_email"]
        }
    }

    private static let byName: [String: ToolAccess] = {
        var table: [String: ToolAccess] = [:]
        for access in allCases {
            for name in access.toolNames { table[name] = access }
        }
        return table
    }()

    static func of(_ toolName: String) -> ToolAccess? { byName[toolName] }
}
