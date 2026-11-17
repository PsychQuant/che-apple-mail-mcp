## Summary

`search_emails` gets an optional request flag `include_message_id`. When it is true, each `full` or `summary` row carries `message_id`, read from the `.emlx` header block with the parser `get_email` and the batch export use (#682).

## Motivation

The `/archive-mail` SOP de-duplicates on Message-ID. Since #643 it calls `get_email_headers` once per row that lacks one and reads the value out of raw header text, which costs one call per row and passes sender-controlled text through the agent's context. Returning the parsed value from the server removes both. Decisions B1 and B2 on the issue: a request flag, default false; the source is the `.emlx` header block (the Envelope Index column is measured separately, #709).

## Proposed Solution

- `include_message_id` (boolean, default false) on `search_emails`; present and not a boolean is a parameter error; `true` with `ids` or `count` is a parameter error.
- A header-only reader in `MailSQLite` (`EmlxParser.readMessageID`) reads chunks until the end of the header block and returns `RFC822Parser.parseHeaders(...)["message-id"] ?? ""`; `readEmail` takes the value through the same helper, so the two cannot drift.
- A per-call lookup resolves each mailbox's store folder once and turns a result into value / empty string / unreadable; the server omits the key for unreadable rows and writes one stderr line per call.
- `SearchResult` carries the raw mailbox URL so the lookup can resolve the file.
- Spec, tool description, input schema, README and CHANGELOG say the same.

## Non-Goals

- Reading the Envelope Index column (#709).
- The AppleScript fallback, `ids`, `count` and `list_emails` rows.
- The `/archive-mail` Step 3d rewrite (#643, #652), which waits for a binary release that contains this field.
- A live run against a real mail store (not part of this change; see the verification note in the pull request).

## Impact

- Affected specs: `sqlite-query-engine` (MODIFIED "Search result projection and logical dedup"; ADDED "search_emails returns the Message-ID on request")
- Affected code: `Sources/MailSQLite/EmlxParser.swift`, `EmlxFormat.swift`, `EmailContent.swift`, `SearchResult.swift`, `EnvelopeIndexReader.swift`; new `MessageIDLookup.swift`; `Sources/CheAppleMailMCP/Server.swift`
- Docs: `README.md`, `CHANGELOG.md`
- Release order: server release first, then a plugin release whose `binary_version` is that binary or later.
