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

We defend against:
- AppleScript injection via crafted tool parameters (#50: `id` Int validation
  at handler boundary)
- Path traversal / sensitive file exfil via attachments (#38: deny-list +
  optional allow-list for attachment paths)
- Email header injection via crafted addresses (#41: RFC 5322 addr-spec +
  control-char rejection at recipient validation)
- Type-coercion silent failures (#35: typed helpers `requireBool` /
  `optionalStringArray` reject non-matching types instead of silent default)

We do NOT defend against:
- Local user with shell access (out of trust boundary; Mail.app is already
  fully accessible)
- Mail.app itself being compromised (out of scope; we wrap its scripting)
- Side-channel timing or memory attacks (out of scope for an interactive tool)

## Attachment Path Policy (since #38)

`compose_email` and `create_draft` accept an `attachments` parameter — a list
of POSIX file paths to attach to the outgoing message. Without input
validation, a malicious / hallucinated MCP caller could pass
`attachments=["~/.ssh/id_ed25519"]` and have it silently attached to a draft
(combined with `save_as_draft=true`, the user never sees the popup).

`reply_email` also has an `attachments` parameter, but since #534 any non-empty
list is refused before a file is read, so no reply attaches a file and the
checks below do not run on that path. When #608 restores reply attachments, it
must run the reply's paths through the same checks (`validateAttachmentPaths`).

The server defends against this with five layers, applied in order:

### 1. Existence

Each path must point to an existing file. `MailError.invalidParameter` thrown
on miss with a list of all missing paths (so the LLM can self-correct on retry
without one-at-a-time iteration).

### 2. Symlink resolution

Every path is made absolute (a relative path counts from the server's working
directory) and resolved with `URL(fileURLWithPath:).resolvingSymlinksInPath()`
**before** the deny-list check. This defeats the
`~/Documents/decoy_pdf → ~/.ssh/id_ed25519` symlink-bypass. The path is not
`.standardized` first: that removed `..` from the text before links were
followed, so `link/../file` was judged at `dir/file` while the kernel opened the
`file` next to the link's target, which let a decoy pass every layer
([#543](https://github.com/PsychQuant/che-apple-mail-mcp/issues/543)). All later
layers judge this one resolved path.

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

### 5. Regular files only

The resolved path must be a regular file ([#543](https://github.com/PsychQuant/che-apple-mail-mcp/issues/543)),
for `compose_email`, `create_draft` and `update_draft` (which checks before it
scans for the draft to replace).
Directories (including package directories such as `.rtfd` or `.app`), FIFOs,
sockets, character and block devices, and a path that is still a symbolic link
after resolution are rejected as `not a regular file (<kind>)`. The type is read
without opening the path, so a FIFO with no writer cannot block validation. A
reader that later opens the file must still check the opened descriptor: the
check at validation time does not cover a path swapped afterwards.

### Known limitations

- **TOCTOU**: validation runs in this server, but Mail opens the attachment in
  its own process after the compose window is up, seconds later (each
  attachment adds a few seconds of GUI steps, so with 50 attachments the last
  one is attached minutes after validation). Anything able to replace the path
  in that window defeats every layer, the regular-file check included. Not
  mitigated; an in-process reader (#479) must re-check the opened descriptor.
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

### `id` parameter is validated as Int (since v2.6.0 / #50)

All 17 message-id-taking MCP tools now hard-fail at the handler boundary if
the `id` parameter is missing, empty, non-string, or non-numeric. Prior to
v2.6.0, a crafted `id` like `"123 whose subject is \"x\" or true ..."` could
cause Mail.app to return the wrong message via AppleScript predicate
short-circuit.

This is now handled at the Server.swift handler layer via `requireMessageId`,
with a `MailController.msgRef` debug-only assertion as defense in depth.

The `id` JSON Schema remains `string` (callers don't need to change encoding);
runtime validation is strictly stronger than the schema.

## Audit Trail

| Date | Issue | Fix |
|------|-------|-----|
| 2026-05-03 | [#48](https://github.com/PsychQuant/che-apple-mail-mcp/issues/48) | SECURITY.md created — RFC 3676 nested quote forgery limitation documented |
| 2026-05-03 | [#38](https://github.com/PsychQuant/che-apple-mail-mcp/issues/38) | Attachment path validation: deny-list + symlink resolution + opt-in allow-list |
| 2026-05-03 | [#50](https://github.com/PsychQuant/che-apple-mail-mcp/issues/50) | `id` injection at msgRef AppleScript interpolation — Int validation at handler boundary |
| 2026-11-11 | [#543](https://github.com/PsychQuant/che-apple-mail-mcp/issues/543) | Attachment path validation: reject anything that is not a regular file after symlink resolution; resolve `..` after a symlink from the link's target (no `.standardized`); `update_draft` validates before scanning drafts |
