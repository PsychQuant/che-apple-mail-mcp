# Security Policy

## Reporting Security Issues

If you discover a security issue in `che-apple-mail-mcp`, please:

- **Do NOT** open a public GitHub issue with exploit details
- Email the maintainer privately, OR
- Open a GitHub Security Advisory at <https://github.com/PsychQuant/che-apple-mail-mcp/security/advisories/new>

We aim to respond within 7 days.

## Supported Versions

Only the latest minor release receives security fixes. Older versions will not be patched — pin to the latest tag in your `che-apple-mail-mcp-wrapper.sh`.

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
