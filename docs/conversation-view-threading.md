# Mail.app Conversation-View Threading Verification

> **Status**: template / data-collection harness. To be filled in by manual smoke test.
> **Tracks**: [#47](https://github.com/PsychQuant/che-apple-mail-mcp/issues/47)
> **Related**: [#43](https://github.com/PsychQuant/che-apple-mail-mcp/issues/43) — the user-reported symptom that motivated this verification

## Why this verification exists

#43's user-reported symptom was:

> "save_as_draft=true 場景: user 看 Drafts 內 draft 像「不在 thread 裡」(其實 In-Reply-To/References 都對),因為 Mail.app conversation view 也參考 body 的 quoted content"
> — issue #43 body, line 56

The hypothesized root cause was "body lacks quoted original" (Mail.app conversation-view grouping reportedly considers body content in addition to RFC 5322 `In-Reply-To` / `References` headers). #43 fixed the hypothesized root cause (added RFC 3676 `> ` quote in plain mode), but **never verified the user-visible symptom resolved**.

If RFC 3676 plain `> ` is NOT what Mail.app's conversation-view algorithm considers (only `<blockquote>` HTML?), then #43 fixed root cause A but symptom B persists.

## Test setup

Required: macOS Mail.app, an iCloud account (or any account showing conversation view), at least one real reply thread with intact `In-Reply-To` / `References` headers in INBOX.

1. Identify a real reply thread:
   ```
   search_emails(query="<your test thread subject>", field="subject")
   # Note the thread's "head" (oldest) message id
   ```
2. Confirm thread integrity in Mail.app: enable conversation view (View → Organize by Conversation), confirm the existing replies appear collapsed under one row with disclosure triangle.

## Test protocol

For each format (plain → markdown → html), repeat:

```
reply_email(
    id="<head message id>",
    mailbox="INBOX",
    account_name="<account>",
    body="Conversation-view threading test (#47, format=<format>)",
    save_as_draft=true,
    format="<format>"
)
```

Then in Mail.app:
- Switch to conversation view if not already
- Locate the original thread
- **Question**: does the new draft appear collapsed inside the original thread (disclosure triangle now shows N+1 messages)?

## Results matrix

Test conducted: **TBD**. CHE-APPLE-MAIL-MCP version: **v2.5.0+**.

| Format | Quote in body? | Draft groups into thread? | Notes |
|---|---|---|---|
| `plain` | RFC 3676 `> ` (since #43) | TBD | Critical case for #47 |
| `markdown` | `<blockquote>` HTML | TBD | If groups, `<blockquote>` is sufficient |
| `html` | `<blockquote>` HTML | TBD | Same as markdown |

## Conclusion drivers

| Outcome | Action |
|---|---|
| All three formats group correctly | ✓ #43 fix complete; close #47 with positive result |
| Only HTML groups, plain does not | Plain mode insufficient. Investigate: (a) switch default `format` from `plain` to `html` in `reply_email` (regression — bigger conversation), or (b) make plain mode emit MIME structure that conversation-view recognizes |
| None group | Conversation-view doesn't use body. Different root cause for the original symptom — need separate investigation. Likely In-Reply-To / References issue |

## Additional inspection

If the answer is unclear, deep-dive on the MIME structure:

```
get_email(id="<draft id>", mailbox="Drafts", account_name="<account>", format="source")
```

Compare:
- Manual `Cmd+R` reply MIME structure
- `reply_email` (plain) MIME structure
- `reply_email` (html) MIME structure

Differences in `Content-Type` boundary, charset, or header presence may indicate what conversation-view keys on.

## Historical context

- **2026-05-03 (v2.5.0 / #43)**: shipped RFC 3676 `> ` quote in plain mode. User's symptom (draft not in thread) reported pre-#43; not re-verified post-#43.
- **Pending**: results from this verification.
