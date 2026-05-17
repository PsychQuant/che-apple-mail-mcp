# che-apple-mail-mcp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![MCP](https://img.shields.io/badge/MCP-Compatible-green.svg)](https://modelcontextprotocol.io/)

**The most comprehensive Apple Mail MCP server** - 48 tools with SQLite-powered millisecond search across 250K+ emails.

[English](README.md) | [繁體中文](README_zh-TW.md)

---

## Why che-apple-mail-mcp?

| Feature | Other MCPs | che-apple-mail-mcp |
|---------|------------|-------------------|
| Total Tools | ~20 | **47** |
| Language | Python | **Swift (Native)** |
| Search Speed | Seconds (AppleScript) | **Milliseconds (SQLite)** |
| Search Fields | Subject/Sender | **Subject/Sender/Recipient/Date** |
| Batch Operations | No | **Up to 50 emails per call** |
| Mailbox Management | Basic | Full CRUD |
| Email Colors | No | 7 flag colors + background |
| VIP Management | No | Yes |
| Rule Management | Partial | Full CRUD |
| Signatures | No | Yes |
| Raw Headers/Source | No | Yes |

---

## Quick Start

```bash
# Clone and build
git clone https://github.com/kiki830621/che-apple-mail-mcp.git
cd che-apple-mail-mcp
swift build -c release

# Copy to ~/bin and add to Claude Code
# --scope user    : available across all projects (stored in ~/.claude.json)
# --transport stdio: local binary execution via stdin/stdout
# --              : separator between claude options and the command
mkdir -p ~/bin
cp .build/release/CheAppleMailMCP ~/bin/
claude mcp add --scope user --transport stdio che-apple-mail-mcp -- ~/bin/CheAppleMailMCP
```

> **💡 Tip:** Always install the binary to a local directory like `~/bin/`. Avoid placing it in cloud-synced folders (Dropbox, iCloud, OneDrive) as file sync operations can cause MCP connection timeouts.

Then grant Automation permission in **System Settings > Privacy & Security > Automation**.

---

## Recent Releases

For full details see [CHANGELOG.md](CHANGELOG.md).

### v2.7.2 (2026-05-10) — `attachmentFragment` cluster + fallback parity
- Hardened `attachmentFragment` indent across all 3 callers + removed dead `MailController.attachmentScript` helper that bypassed v2.7.0's race-mitigation delays ([#61](https://github.com/PsychQuant/che-apple-mail-mcp/issues/61), [#62](https://github.com/PsychQuant/che-apple-mail-mcp/issues/62))
- Attachment count cap (50) + env-configurable delays via `CHE_MAIL_ATTACHMENT_DELAY_BETWEEN` / `_TRAILING` ([#63](https://github.com/PsychQuant/che-apple-mail-mcp/issues/63), [#64](https://github.com/PsychQuant/che-apple-mail-mcp/issues/64))
- `get_email_metadata` SQLite path now falls back to AppleScript on error — last read-tool gap closed; all 8 SQLite-first read tools now have parity fallback ([#71](https://github.com/PsychQuant/che-apple-mail-mcp/issues/71))

### v2.7.1 (2026-05-09) — base64 fix + `.partial.emlx` + observability
- **Critical**: RFC822 header/body split was returning a relative array index instead of an absolute `Data` index, causing `html_body` to begin with `"sion: 1.0\n\n<base64>"` for some Android Gmail messages — raw base64 leaked into LLM context and triggered AUP false-positives downstream ([#72](https://github.com/PsychQuant/che-apple-mail-mcp/issues/72))
- `save_attachment` now reads from `Attachments/<rowId>/<part_id>/<filename>` cache when `.partial.emlx` body is empty — no more silent 0-byte writes for IMAP messages with stripped binaries ([#66](https://github.com/PsychQuant/che-apple-mail-mcp/issues/66))
- SQLite fast-path failures now log to stderr (`SQLite ... fast path failed for rowId=...; falling through to AppleScript`) ([#69](https://github.com/PsychQuant/che-apple-mail-mcp/issues/69))

### v2.7.0 (2026-05-04) — Mail.app race mitigation
- Multi-attachment AppleScript paced with 0.3s between + 0.5s trailing delays to mitigate Mail.app silently dropping attachments under fast IPC ([#60](https://github.com/PsychQuant/che-apple-mail-mcp/issues/60))

### v2.6.0 (2026-05-03) — Security & validation hardening (8 PRs, 16 issues)
- `forward_email` plain mode now embeds RFC 3676 `> ` quoted original (parity with `reply_email`'s #43 fix) ([#44](https://github.com/PsychQuant/che-apple-mail-mcp/issues/44))
- Hard-fail on tool param type mismatch — `bool` / `[String]` no longer silently coerced ([#35](https://github.com/PsychQuant/che-apple-mail-mcp/issues/35))
- Recipient email validation rejects header injection (control chars, missing/multiple `@`) ([#41](https://github.com/PsychQuant/che-apple-mail-mcp/issues/41))
- `cc_additional` deduplicates case-insensitively ([#34](https://github.com/PsychQuant/che-apple-mail-mcp/issues/34))
- Attachment path deny-list (`~/.ssh`, Keychains, TCC db, browser cookies) + symlink-resolved + new `MAIL_MCP_ATTACHMENT_ROOTS` env allow-list ([#38](https://github.com/PsychQuant/che-apple-mail-mcp/issues/38))
- All 17 id-taking tools hard-validate `id` as Int at handler boundary — defeats AppleScript predicate injection ([#50](https://github.com/PsychQuant/che-apple-mail-mcp/issues/50))
- Gated integration tests for `reply_email` runtime ([#37](https://github.com/PsychQuant/che-apple-mail-mcp/issues/37), [#45](https://github.com/PsychQuant/che-apple-mail-mcp/issues/45)) + smoke matrix templates ([#46](https://github.com/PsychQuant/che-apple-mail-mcp/issues/46), [#47](https://github.com/PsychQuant/che-apple-mail-mcp/issues/47))

### v2.5.0 (2026-04-17) — Composing `format` parameter
- All 4 composing tools (`compose_email` / `create_draft` / `reply_email` / `forward_email`) gain `format: "plain" | "markdown" | "html"` param (closes [#14](https://github.com/PsychQuant/che-apple-mail-mcp/issues/14), [#15](https://github.com/PsychQuant/che-apple-mail-mcp/issues/15))
- New `message-composition` capability spec

---

## All 48 Tools

<details>
<summary><b>Accounts (2)</b></summary>

| Tool | Description |
|------|-------------|
| `list_accounts` | List all mail accounts |
| `get_account_info` | Get account details |

</details>

<details>
<summary><b>Mailboxes (4)</b></summary>

| Tool | Description |
|------|-------------|
| `list_mailboxes` | List all mailboxes (folders) |
| `create_mailbox` | Create a new mailbox |
| `delete_mailbox` | Delete a mailbox |
| `get_special_mailboxes` | Get special mailbox names (inbox, drafts, sent, trash, junk, outbox) |

</details>

<details>
<summary><b>Emails (7)</b></summary>

| Tool | Description |
|------|-------------|
| `list_emails` | List emails in a mailbox |
| `get_email` | Get full email content |
| `search_emails` | Search by subject/content |
| `get_unread_count` | Get unread count |
| `get_email_headers` | Get all email headers |
| `get_email_source` | Get raw email source |
| `get_email_metadata` | Get metadata (forwarded, replied, size) |

</details>

<details>
<summary><b>Actions (8)</b></summary>

| Tool | Description |
|------|-------------|
| `mark_read` | Mark as read/unread |
| `flag_email` | Flag/unflag email |
| `set_flag_color` | Set flag color (7 colors) |
| `set_background_color` | Set email background color |
| `mark_as_junk` | Mark as junk/not junk |
| `move_email` | Move to another mailbox |
| `copy_email` | Copy to another mailbox |
| `delete_email` | Delete email (to trash) |

</details>

<details>
<summary><b>Compose (5)</b></summary>

| Tool | Description |
|------|-------------|
| `compose_email` | Send new email (supports cc/bcc/attachments; `format`: plain/markdown/html) |
| `reply_email` | Reply to email. Optional: `cc_additional`, `attachments`, `save_as_draft`, `format` (since v2.4.0). Plain mode embeds RFC 3676 `> ` quoted original (since v2.5.0 / #43) |
| `forward_email` | Forward email. Optional `body` + `format`. Plain mode embeds RFC 3676 `> ` quoted original (since v2.5.0+ / #44) |
| `redirect_email` | Redirect email (keeps original sender) |
| `open_mailto` | Open mailto URL |

#### Reply-as-draft example (v2.4.0+)

Reply to a thread, add extra CC, attach files, and save as a draft for human review before sending:

```
reply_email(
    id="<message id from search_emails>",
    mailbox="INBOX",
    account_name="iCloud",
    body="Reply text",
    cc_additional=["x@y.com"],
    attachments=["/path/to/file.pdf"],
    save_as_draft=true
)
```

</details>

<details>
<summary><b>Drafts (2)</b></summary>

| Tool | Description |
|------|-------------|
| `list_drafts` | List draft emails |
| `create_draft` | Create a draft (supports attachments) |

</details>

<details>
<summary><b>Attachments (2)</b></summary>

| Tool | Description |
|------|-------------|
| `list_attachments` | List email attachments |
| `save_attachment` | Save attachment to disk |

</details>

<details>
<summary><b>VIP (1)</b></summary>

| Tool | Description |
|------|-------------|
| `list_vip_senders` | List VIP senders |

</details>

<details>
<summary><b>Rules (5)</b></summary>

| Tool | Description |
|------|-------------|
| `list_rules` | List mail rules |
| `get_rule_details` | Get rule details |
| `create_rule` | Create a new rule |
| `delete_rule` | Delete a rule |
| `enable_rule` | Enable/disable a rule |

</details>

<details>
<summary><b>Signatures (2)</b></summary>

| Tool | Description |
|------|-------------|
| `list_signatures` | List email signatures |
| `get_signature` | Get signature content |

</details>

<details>
<summary><b>SMTP (1)</b></summary>

| Tool | Description |
|------|-------------|
| `list_smtp_servers` | List SMTP servers |

</details>

<details>
<summary><b>Sync (2)</b></summary>

| Tool | Description |
|------|-------------|
| `check_for_new_mail` | Check for new mail |
| `synchronize_account` | Sync IMAP account |

</details>

<details>
<summary><b>Utilities (4)</b></summary>

| Tool | Description |
|------|-------------|
| `extract_name_from_address` | Extract name from email address |
| `extract_address` | Extract email from full address |
| `get_mail_app_info` | Get Mail.app info |
| `import_mailbox` | Import mailbox from file |

</details>

---

## Installation

### Requirements

- macOS 13.0+
- Xcode Command Line Tools
- Apple Mail with at least one account configured

### Step 1: Build

```bash
git clone https://github.com/kiki830621/che-apple-mail-mcp.git
cd che-apple-mail-mcp
swift build -c release
```

### Step 2: Configure

#### For Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "che-apple-mail-mcp": {
      "command": "/full/path/to/che-apple-mail-mcp/.build/release/CheAppleMailMCP"
    }
  }
}
```

#### For Claude Code (CLI)

```bash
# Copy to ~/bin and register (user scope = available in all projects)
mkdir -p ~/bin
cp .build/release/CheAppleMailMCP ~/bin/
claude mcp add --scope user --transport stdio che-apple-mail-mcp -- ~/bin/CheAppleMailMCP
```

### Step 3: Grant Permissions

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
```

1. Find **CheAppleMailMCP** and enable permission for **Mail.app**
2. If using Claude Code, also add **Terminal** or **iTerm**

### Step 4: Restart Claude

```bash
# For Claude Desktop
osascript -e 'quit app "Claude"' && sleep 2 && open -a "Claude"

# For Claude Code - start a new session
claude
```

---

## Usage Examples

### Natural Language (Claude Desktop)

```
"List all my mail accounts"
"Show unread emails in Gmail inbox"
"Search for emails about 'quarterly report'"
"Send an email to john@example.com about the meeting"
"Flag important emails in red"
"Create a rule to move newsletters to a folder"
```

### Direct Tool Calls (Claude Code)

```
"Use list_accounts to show my accounts"
"Use search_emails to find emails containing 'invoice'"
"Use set_flag_color to mark email ID 12345 as blue"
"Use check_for_new_mail to refresh"
```

---

## Flag & Background Colors

### Flag Colors (`set_flag_color`)

| Index | Color |
|-------|-------|
| 0 | Red |
| 1 | Orange |
| 2 | Yellow |
| 3 | Green |
| 4 | Blue |
| 5 | Purple |
| 6 | Gray |
| -1 | Clear |

### Background Colors (`set_background_color`)

`blue`, `gray`, `green`, `none`, `orange`, `purple`, `red`, `yellow`

---

## Performance & Storage

### SQLite + .emlx fast path

Most read tools prefer Apple Mail's local Envelope Index (SQLite) and on-disk `.emlx` message files over AppleScript IPC, with transparent AppleScript fallback when the SQLite path can't satisfy a request:

| Tool | SQLite/.emlx path | AppleScript fallback |
|------|------------------|----------------------|
| `get_email` | ✓ | ✓ on any error |
| `get_emails_batch` | ✓ (per item) | ✓ (per item) |
| `get_email_headers` | ✓ | ✓ on any error |
| `get_email_source` | ✓ | ✓ on any error |
| `search_emails` | ✓ | ✓ when reader unavailable |
| `list_attachments` | ✓ | ✓ on any error |
| `save_attachment` | ✓ | ✓ on any error |
| `get_email_metadata` | ✓ | ✓ on any error (since [#71](https://github.com/PsychQuant/che-apple-mail-mcp/issues/71)) |

For `save_attachment`'s read path the fast path is **10–100× faster** than AppleScript (per [#12](https://github.com/PsychQuant/che-apple-mail-mcp/issues/12) measurements). Other tools' speedup ratios depend on request shape; in general, large bulk reads see the biggest gain.

The fast path requires:

- Full Disk Access granted to the host process (System Settings → Privacy & Security → Full Disk Access)
- Apple Mail's local store at `~/Library/Mail/V10/...`
- Message has been synced to local `.emlx` storage

### EWS / Exchange accounts intentionally bypass the fast path

Exchange (EWS) accounts in Apple Mail **do not materialize `.emlx` files** — message bodies live on the server and are fetched on demand. For these accounts, all 8 read tools (including `get_email_metadata` since [#71](https://github.com/PsychQuant/che-apple-mail-mcp/issues/71)) transparently degrade to AppleScript IPC (which is correct but slower). Symptoms:

- A bulk fetch of 500 EWS messages will be noticeably slower than 500 IMAP/Gmail messages
- This is **not a bug** — it's an Apple Mail storage architecture constraint (see [#9](https://github.com/PsychQuant/che-apple-mail-mcp/issues/9))

### Diagnosing fast-path bypass

When the fast path fails for a non-EWS account, the failure is logged to stderr (since [#69](https://github.com/PsychQuant/che-apple-mail-mcp/issues/69)). Run the binary in a terminal and watch stderr to distinguish:

- `EnvelopeIndexReader init failed: ...` — DB unreachable (commonly: Full Disk Access missing)
- `SQLite get_email fast path failed for rowId=N: ...` — per-message failure (e.g., `.partial.emlx` only, malformed MIME, file not yet synced)

Both cases transparently fall through to AppleScript with `... falling through to AppleScript` in the log line, so behavior is preserved while observability is restored.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Server disconnected | Rebuild with `swift build -c release` |
| Not allowed to send Apple events | Add permissions in System Settings > Automation |
| Mail.app not responding | Ensure Mail.app is running with configured accounts |
| Commands timing out | Large mailboxes take longer; try specific searches |
| Bulk fetch slower than expected | Watch stderr for `... falling through to AppleScript` lines. EWS/Exchange accounts always fall back (see [Performance & Storage](#performance--storage)); other accounts logging fallback indicate a fixable .emlx issue |
| `save_attachment` fails with `-1728 "Can't get account"` or `-1719 "Invalid mailbox index"` | Two Mail.app accounts share the same `display_name` (e.g., iCloud catch-all alias + Gmail with the same address). See [Account Disambiguation](#account-disambiguation) below. |

---

## Account Disambiguation

Mail.app's AppleScript `account "<display_name>"` selector is **not unique** when two accounts share the same `display_name` — a common pattern when an iCloud catch-all alias forwards a Gmail address back to itself, or when Google Workspace + personal Gmail overlap. Any AppleScript-routed tool (`save_attachment` fallback, `get_email`, `mark_read`, etc.) will then non-deterministically pick the wrong account → `-1728 / -1719` errors.

**The fix**: pass `account_id` (Mail.app's globally-unique UUID) alongside `account_name`. When provided, `save_attachment` uses Mail.app's `account id "<UUID>"` selector instead, bypassing the ambiguity:

```jsonc
// Tool call: save_attachment with account_id
{
    "id": "273214",
    "mailbox": "[Gmail]/全部郵件",
    "account_name": "kiki830621@gmail.com",
    "account_id": "C38E0583-47F8-4468-BE70-43155C15549D",  // ← disambiguates
    "attachment_name": "report.pdf",
    "save_path": "/tmp/report.pdf"
}
```

**Discovering `account_id`**:

- **From `search_emails` results** — each `SearchResult` carries an `account_id` field alongside `account_name` (populated from the `mailboxes.account_id` SQLite join). Recommended: pass it through directly.
- **Manually** — read `~/Library/Mail/V10/MailData/Signatures/AccountsMap.plist`. The top-level keys are the UUIDs; the `AccountURL` value contains the matching email address percent-encoded in the authority.
- **In AppleScript** — `tell application "Mail" to get id of every account` returns the UUID list.

**Backward compatibility**: `account_id` is **optional**. When omitted (or empty), tools fall back to the legacy `account "<display_name>"` path — behavior identical to pre-#101. Existing callers continue to work unchanged.

**Scope**: as of this release, `account_id` is accepted by `save_attachment` plus the 5 single-message mutation tools `mark_read`, `flag_email`, `set_flag_color`, `set_background_color`, and `mark_as_junk` (PR-A of the [#104](https://github.com/PsychQuant/che-apple-mail-mcp/issues/104) sweep). The same disambiguation pattern will be applied to the remaining AppleScript-routed tools (move/copy/delete, compose, mailbox CRUD) in subsequent PRs tracked at [#104](https://github.com/PsychQuant/che-apple-mail-mcp/issues/104).

---

## Technical Details

- **Framework**: [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) v0.10.0
- **Read path**: SQLite (Envelope Index) + `.emlx` file parser, with AppleScript fallback for EWS / unparseable `.emlx`
- **Write/state path**: AppleScript via `NSAppleScript`
- **Transport**: stdio
- **Platform**: macOS 13.0+ (Ventura and later)

---

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Author

Created by **Che Cheng** ([@kiki830621](https://github.com/kiki830621))

If you find this useful, please consider giving it a star!
