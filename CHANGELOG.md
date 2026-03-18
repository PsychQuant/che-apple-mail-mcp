# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-03-18

### Added
- Optional `attachments` parameter for `compose_email` and `create_draft` (#1)
  - Accepts array of absolute file paths
  - Validates file existence before attaching
  - Fully backward compatible

### Fixed
- AppleScript parse error (-2741) with Chinese characters and multi-line content (#2)
  - Root cause: C-style `\n` escape not supported in AppleScript strings
  - Fix: use AppleScript-native `" & return & "` concatenation for newlines and tabs

---

## [1.0.0] - 2026-01-13

### Added
- **42 comprehensive tools** covering nearly all Apple Mail scripting capabilities
- **Account Management**: `list_accounts`, `get_account_info`
- **Mailbox Operations**: `list_mailboxes`, `create_mailbox`, `delete_mailbox`, `get_special_mailboxes`
- **Email Operations**: `list_emails`, `get_email`, `search_emails`, `get_unread_count`, `get_email_headers`, `get_email_source`, `get_email_metadata`
- **Email Actions**: `mark_read`, `flag_email`, `set_flag_color` (7 colors), `set_background_color`, `mark_as_junk`, `move_email`, `copy_email`, `delete_email`
- **Compose**: `compose_email`, `reply_email`, `forward_email`, `redirect_email`, `open_mailto`
- **Drafts**: `list_drafts`, `create_draft`
- **Attachments**: `list_attachments`, `save_attachment`
- **VIP**: `list_vip_senders`
- **Rules**: `list_rules`, `get_rule_details`, `create_rule`, `delete_rule`, `enable_rule`
- **Signatures**: `list_signatures`, `get_signature`
- **SMTP**: `list_smtp_servers`
- **Sync**: `check_for_new_mail`, `synchronize_account`
- **Utilities**: `extract_name_from_address`, `extract_address`, `get_mail_app_info`, `import_mailbox`
- Native Swift implementation with MCP Swift SDK v0.10.0
- Comprehensive test scripts for all features

---

## Tool Count by Version

| Version | Total Tools | Notes |
|---------|-------------|-------|
| 1.1.0   | 42          | Attachments support for compose/draft, CJK encoding fix |
| 1.0.0   | 42          | Initial release with full Mail.app coverage |
