# Security Policy

## Reporting Security Issues

If you discover a security issue in `che-apple-mail-mcp`, please:

- **Do NOT** open a public GitHub issue with exploit details
- Email the maintainer privately, OR
- Open a GitHub Security Advisory at <https://github.com/PsychQuant/che-apple-mail-mcp/security/advisories/new>

We aim to respond within 7 days.

## Supported Versions

Only the latest minor release receives security fixes. Older versions will not
be patched — pin to the latest tag in your `che-apple-mail-mcp-wrapper.sh`.

## Threat Model

`che-apple-mail-mcp` runs as a local macOS process (single-user, AppleScript-
backed). The trust boundary is the **MCP transport** — anything that reaches the
tool handler should be treated as untrusted (LLM-generated, possibly prompt-
injected from inbound email content). The Mail.app side runs with the user's
local privileges.

We do NOT defend against:
- Local user with shell access (out of trust boundary; Mail.app is already
  fully accessible)
- Mail.app itself being compromised (out of scope; we wrap its scripting)
- Side-channel timing or memory attacks (out of scope for an interactive tool)

## Attachment Path Policy (since #38)

`compose_email`, `create_draft`, and `reply_email` accept an `attachments`
parameter — a list of POSIX file paths to attach to the outgoing message.
Without input validation, a malicious / hallucinated MCP caller could pass
`attachments=["~/.ssh/id_ed25519"]` and have it silently attached to a draft
(combined with `save_as_draft=true`, the user never sees the popup).

The server defends against this with three layers, applied in order:

### 1. Existence

Each path must point to an existing file. `MailError.invalidParameter` thrown
on miss with a list of all missing paths (so the LLM can self-correct on retry
without one-at-a-time iteration).

### 2. Symlink resolution

Every path is canonicalized via `URL(fileURLWithPath:).standardized.resolvingSymlinksInPath()`
**before** the deny-list check. This defeats the
`~/Documents/decoy_pdf → ~/.ssh/id_ed25519` symlink-bypass.

### 3. Hardcoded deny-list (default-on)

After resolution, paths under any of the following directories are rejected:

- `~/.ssh/`
- `~/Library/Keychains/`
- `~/Library/Application Support/com.apple.TCC/`
- `~/Library/Cookies/`
- `~/Library/Application Support/Google/Chrome/`
- `~/Library/Application Support/Safari/`
- `/etc/`, `/var/`, `/private/`

This list is conservative — it catches the obvious sensitive directories
without breaking common attachment workflows from `~/Documents/`,
`~/Downloads/`, `~/Desktop/`.

### 4. Optional allow-list (opt-in via env var)

If `MAIL_MCP_ATTACHMENT_ROOTS` is set in the server's environment (colon-
separated list of paths; leading `~` expanded), attachments must additionally
resolve under one of these roots. Example for a security-conscious deployment:

```bash
MAIL_MCP_ATTACHMENT_ROOTS=~/Documents/letters:~/Downloads/safe-attach
```

When unset (default), only the deny-list applies.

### Known limitations

- **TOCTOU**: a sufficiently fast attacker could swap a symlink between
  validation and AppleScript-attach. Practical risk is microseconds; same-
  process synchronous gap. Not mitigated.
- **macOS sandboxing interaction**: if the MCP server runs with restricted
  entitlements, some deny-list paths may already be unreadable. Defense in
  depth — our check fires before FileManager attempts the read.
- **The deny-list is hardcoded**. Future enhancement: env var
  `MAIL_MCP_ATTACHMENT_DENY_EXTRA` for runtime extension. Not currently
  implemented.
- **`save_attachment` write-side**: writes attachments to user-supplied paths.
  Not yet protected by an analogous deny-list. Tracked separately.

## Known Limitations

### RFC 3676 nested quote forgery in `reply_email` (#48)

`reply_email` (plain mode, default since v2.5.0) prepends RFC 3676 `> ` line-prefixes to the original message body when composing a reply. If an attacker sends a message whose plain body already contains `> `-prefixed lines (forged quoted conversation), `reply_email` will faithfully emit `>> `-prefixed nested quotes. Most mail clients (Outlook, Gmail, Apple Mail) render this as a multi-level quote chain visually identical to a genuine prior conversation.

This is consistent with [RFC 3676 §4.5](https://datatracker.ietf.org/doc/html/rfc3676#section-4.5) and is the same behavior every mainstream mail client exhibits. We provide no detection or filtering of forged quote content because no signal distinguishes it from legitimate quotes.

**Mitigation for end users**: Treat suspicious quoted blocks in received mail with the same skepticism as the rest of the body content. Verify quoted "prior conversations" out-of-band before acting on them.

Discovered during 6-AI verify of [#43](https://github.com/PsychQuant/che-apple-mail-mcp/issues/43). Tracked in [#48](https://github.com/PsychQuant/che-apple-mail-mcp/issues/48).

## Audit Trail

| Date | Issue | Fix |
|------|-------|-----|
| 2026-05-03 | [#48](https://github.com/PsychQuant/che-apple-mail-mcp/issues/48) | SECURITY.md created (this document) — RFC 3676 nested quote forgery limitation documented |
| 2026-05-03 | [#38](https://github.com/PsychQuant/che-apple-mail-mcp/issues/38) | Attachment path validation: deny-list + symlink resolution + opt-in allow-list |
