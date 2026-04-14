# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.2] - 2026-04-14

### Fixed
- **`list_accounts` now returns usable `display_name` for Exchange (EWS) accounts** ([#11](https://github.com/PsychQuant/che-apple-mail-mcp/issues/11)). Previously, the SQLite-first dispatcher returned the account UUID (post-#9) or the raw `ews://AAMkA...` URL (pre-#9) as the account name — neither works as the `account_name` parameter in downstream calls (`get_email`, `search_emails`, etc.), causing AppleScript error -1728. `list_accounts` now walks Mail.app via AppleScript as the primary path and exposes `user_name` + `email_addresses` + `display_name` for every account. IMAP accounts are unchanged; EWS accounts now expose their real email address.

### Added
- `list_accounts` JSON schema extended (**backward compatible** — existing `name` and `uuid` fields preserved):
  - `user_name` (string) — Apple Mail's `user name` attribute, typically the email address
  - `id` (string) — account UUID (same as existing `uuid`, added for schema consistency)
  - `email_addresses` (array of strings) — all addresses associated with the account
  - `display_name` (string) — **canonical identifier to pass back to `get_email` / `search_emails`**. Computed as `user_name ?? email_addresses[0] ?? name`
  - `enabled` (bool) — whether the account is enabled in Mail.app
- New `CheAppleMailMCPTests` test target with 11 unit tests for `AccountsScriptParser` (pure-function parser with no Mail.app dependency — tests IMAP / EWS / multi-account / multi-email / display_name fallback rules / malformed-record resilience)
- New `AccountsScriptParser` type (parses AppleScript output using U+001E/001F/001D control-character separators to avoid the quoting pitfalls of `&` / `,` / newline)

### Changed
- `Server.swift` `list_accounts` dispatcher order **inverted**: AppleScript primary, SQLite fallback (was SQLite primary). Trade-off: `list_accounts` now ~500ms instead of ~10ms, but called only 1-2x per session so cost is acceptable. SQLite path remains as the degraded-mode fallback when Mail.app is unavailable, returning the same JSON schema (though EWS `user_name` / `email_addresses` stay empty on that path — filesystem-only cannot resolve them).
- `EnvelopeIndexReader.listAccounts` extended to emit the same JSON schema as the AppleScript path (additive; legacy `uuid` field preserved).

---

## [2.1.1] - 2026-04-14

### Fixed
- **Exchange/EWS `get_email` / `get_emails_batch` silently failing on real mailboxes** ([#9](https://github.com/PsychQuant/che-apple-mail-mcp/issues/9)). v2.1.0's filesystem-only read path was effectively inert on ~100% of real ROWIDs because `hashDirectoryPath` used a fixed-digit formula that did not match Apple Mail V10's actual variable-depth layout. Verified fix against 256,428 real `.emlx` files across depth 0/1/2/3.
- **`get_emails_batch` swallowing SQLite errors before AppleScript fallback**: the SQLite fast path and AppleScript fallback shared a single `do/catch`, so any `EmlxParser.readEmail` throw was logged as a per-item error and the AppleScript recovery below was never reached. Restructured to match `get_email`'s two-tier catch.
- **EWS account display name leaking raw `AccountURL`** in `search_emails` / `list_accounts` result fields. `AccountMapper.buildMapping` now falls back to the account UUID when `extractEmail` cannot parse an email out of the URL (EWS stores an opaque identifier, not an email). Downstream callers already handle missing entries by returning the UUID via `accountName(for:)`, so behavior for other unmapped cases is unchanged.

### Changed
- `EnvelopeIndexReader.mailStoragePathOverride` dropped from `public` — external modules can no longer redirect mail storage at runtime in release builds. Tests retain access via `@testable import`.
- `mailStoragePathOverride` getter/setter wrapped in `NSLock` to prevent torn reads if tests ever run in parallel (or migrate to swift-testing).

### Documentation
- `openspec/specs/emlx-parser/spec.md` rewritten to describe Apple Mail V10's actual variable-depth layout with concrete examples for depth 0, 1, 2, and 3 (replacing the stale ones/tens/hundreds wording and the wrong ROWID-42 scenario).

---

## [2.1.0] - 2026-04-02

### Added
- All read operations (list_accounts, list_mailboxes, list_emails, get_unread_count, list_attachments, get_email_headers, get_email_source, get_email_metadata, list_vip_senders) now use filesystem-only access (SQLite + .emlx + plist) — zero AppleScript dependency on the read path
- AccountMapper: reads account UUID→name mapping from AccountsMap.plist instead of AppleScript
- Fire-and-forget `check for new mail` at server startup to ensure Envelope Index freshness

### Removed
- `ensureAccountMapping()` AppleScript-based lazy account mapping — replaced by synchronous plist read

---

## [2.0.1] - 2026-04-02

### Fixed
- Server startup hang when Mail.app is not running — AppleScript account mapping calls during `init()` blocked the MCP initialize handshake. Now uses lazy initialization on first search/get_email call.

---

## [2.0.0] - 2026-04-01

### Added
- **SQLite search engine**: Direct queries to Mail.app's Envelope Index database for millisecond-speed search across 250K+ emails
  - New `field` parameter: search by `subject`, `sender`, `recipient`, or `any` (default)
  - New `date_from`/`date_to` parameters for date range filtering (ISO 8601)
  - New `to` field in search results containing recipient addresses
  - Automatic fallback to AppleScript when SQLite is unavailable
- **`.emlx` file parser**: Direct reading of email content from `.emlx` files, bypassing AppleScript
  - RFC 822 header parsing with RFC 2047 encoded-word support (Base64/Quoted-Printable)
  - MIME body parsing (text/plain, text/html, multipart/*, charset conversion)
  - Automatic fallback to AppleScript when `.emlx` files are unavailable
- **Batch operations**: Two new MCP tools for processing multiple emails in a single call
  - `get_emails_batch`: Get content of up to 50 emails at once (uses `.emlx` parser)
  - `list_attachments_batch`: List attachments for up to 50 emails at once
- **MailSQLite library**: New standalone Swift library target with 92 unit/integration tests

### Changed
- `search_emails` default limit changed from 20 to 50
- `get_email` now uses `.emlx` parser as primary source with AppleScript fallback
- Server version bumped to 2.0.0
- Project now has 3 SPM targets: `CheAppleMailMCP` (executable), `MailSQLite` (library), `MailSQLiteTests` (tests)

---

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
