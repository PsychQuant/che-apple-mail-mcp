# RFC 3676 Quote Rendering Matrix

> **Status**: template / data-collection harness. To be filled in by manual smoke test.
> **Tracks**: [#46](https://github.com/PsychQuant/che-apple-mail-mcp/issues/46)
> **Related**: [#43](https://github.com/PsychQuant/che-apple-mail-mcp/issues/43) (the wire-output change being verified)

## Why this matrix exists

`reply_email` plain mode (since v2.5.0 / #43) embeds the original message as RFC 3676 `> `-prefixed quoted text. RFC 3676 is the de facto standard, but mail clients differ in how they render the resulting body. This document tracks empirical observation across major recipient clients so we know whether the format-as-shipped requires further intervention (e.g., adding `Content-Type: text/plain; format=flowed; delsp=no` MIME header).

## Test setup

1. Sender: any account configured in `che-apple-mail-mcp`. Use a real account with sending capability (iCloud, Gmail, Exchange, etc.).
2. Find a real reply thread in the sender INBOX (≥1 known message to reply to).
3. Call:
   ```
   reply_email(
       id="<message id from search_emails>",
       mailbox="INBOX",
       account_name="<account>",
       body="Smoke test reply body — please confirm rendering of the quoted block below.",
       format="plain"
   )
   ```
   (No `save_as_draft` — we want to actually send to the recipient list.)
4. Recipient list: include one address per client below.
5. After receipt, screenshot how each client renders the message and fill in the table.

## Render expectations

What "correct" looks like:
- The recipient's reply block is on top
- A blank line separator
- The quoted original is visually distinguished (sidebar, indent, gray color, collapsible "..." disclosure, etc.) — depending on client convention
- `> ` prefix is NOT shown literally to the user

What "broken" looks like:
- `> ` prefix shown as literal text (no quote rendering)
- Quote block hidden / dropped entirely
- Quote block displayed but indistinguishable from main body

## Matrix

Test conducted: **TBD**. Test message: **TBD**. CHE-APPLE-MAIL-MCP version: **v2.5.0+**.

| Recipient client | Expected | Actual | Notes |
|---|---|---|---|
| Apple Mail (macOS 14 / Sonoma) | quote block w/ vertical sidebar | TBD | Origin client |
| Apple Mail (macOS 26+ / Tahoe) | quote block w/ vertical sidebar | TBD | Verify no regression on newer macOS |
| Apple Mail (iOS 17+) | quote block w/ vertical sidebar | TBD | |
| Gmail web (gmail.com) | collapsed `...` disclosure | TBD | Gmail's standard behavior for `> ` lines |
| Gmail iOS app | similar to web | TBD | |
| Outlook web (Office 365) | quoted block w/ left border | TBD | RFC 3676 compliant per docs |
| Outlook desktop (Windows) | quoted block w/ left border | TBD | |
| Outlook iOS app | similar to desktop | TBD | |
| Thunderbird (latest, plain mode) | quote block w/ left border | TBD | **Risk**: needs `format=flowed` MIME header which we don't set |
| Yahoo Mail web | TBD | TBD | Lower priority |
| ProtonMail web | TBD | TBD | Lower priority |

## Action triggers

- **0-1 fringe clients render incorrectly** → ship as-is, document as known limitation in `SECURITY.md` / `README.md`.
- **A major client (Gmail / Outlook / Apple) renders incorrectly** → escalate to add `Content-Type: text/plain; format=flowed; delsp=no` MIME header. Investigate AppleScript Mail.app surface for MIME header injection — likely requires `.emlx` raw write fallback.

## Test message template

Use this body when testing so observers can grade the rendering objectively:

```
Smoke test for che-apple-mail-mcp #46 / #43.

If you can read this, please reply with how the quoted block below is rendered:
- Visible as a quote block (sidebar / indent / gray text)? → ✓ correct
- Visible as literal "> " prefixed text? → ✗ rendering broken
- Hidden / dropped? → ✗ rendering broken

Thanks!
```

## Historical context

- **2026-05-03 (v2.5.0)**: #43 fix shipped RFC 3676 plain-text quoting. Pre-fix every plain reply since `b8a4a89` (initial release) silently dropped the quote.
- **Pending**: this matrix's first row of data.
