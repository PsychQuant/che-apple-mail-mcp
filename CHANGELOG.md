# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Code fence language hint → `class="language-<hint>"` on `<pre><code>`** ([#22 Item D](https://github.com/PsychQuant/che-apple-mail-mcp/issues/22)). Markdown fences with a language tag (e.g. ` ```swift `, ` ```python `) now emit `<pre><code class="language-swift">…</code></pre>` instead of the previous `<pre><code>…</code></pre>`. CommonMark recommended pattern; honored by Prism / Pygments / highlight.js / mail clients with syntax-highlight plugins. Plain fences without a language tag continue to emit `<pre><code>` unchanged (backwards compatible). Spec.md formally documents this contract.

### Changed
- **Markdown rendering limitations documented in spec** ([#22 Items A/B/C](https://github.com/PsychQuant/che-apple-mail-mcp/issues/22)). Added formal `Requirement: Markdown rendering has documented Foundation parser limitations` block to `openspec/specs/message-composition/spec.md` codifying three known limitations callers should know about: (1) inline emphasis inside a markdown link is collapsed by `AttributedString(markdown:)` — `[**bold** text](url)` renders without the bold (recommend `**[bold text](url)**` or `format: "html"`); (2) C0 control characters (U+0000–U+001F, e.g. U+001E RECORD SEPARATOR) are not round-trip safe through markdown mode — recommend `format: "html"` with entity references or `format: "plain"`. (#22 Item A — attachment indent normalization — was already fixed in v2.7.2 cluster #61, no action needed.)
- **Cross-validation filter extracted to testable helper** ([#28](https://github.com/PsychQuant/che-apple-mail-mcp/issues/28)). The inline filter closure at `Server.swift` `list_attachments` (single-message) and `list_attachments_batch` (per-message) — `sqliteAttachments.filter { entry in ... realNames.contains(name) }` — was identical in both handlers but untested at the handler level (#24's verify DA-2 / Codex P3 finding). Extracted to a top-level `crossValidateAttachments(sqliteAttachments:realNames:)` helper that both call sites now use. Added 6 tests covering: matching entries kept; empty realNames drops everything (Mail.app stale-cache scenario); empty SQLite returns empty; entries without `name` field dropped; entries with non-String `name` (NSNull, Int) dropped; matched entries preserve all fields (size, mimeType, rowId). A bug in the filter logic (inverted condition, missing as? String cast, omitted call) would now fail at least one of the 6 tests immediately. Pure refactor + test addition; zero behavior change.

## [2.8.3] - 2026-05-11

### Changed
- **Chore cluster: 3 sister bugs from cluster A's Step 5.7 sweep** ([#82](https://github.com/PsychQuant/che-apple-mail-mcp/issues/82), [#83](https://github.com/PsychQuant/che-apple-mail-mcp/issues/83), [#84](https://github.com/PsychQuant/che-apple-mail-mcp/issues/84)). (#82) Removed 4 dead `let script = ...` AppleScript declarations in `MailController.swift` (`getAccountInfo`, `listMailboxes`, `listEmails`, `listAttachments`) — each shadowed by a more specific `*Script` variable downstream and never executed; warning count drops by 4. (#83) Migrated 3 deprecated `text(_:metadata:)` MCP SDK factory calls in `Server.swift` to the canonical `.text(text:annotations:_meta:)` enum case; semantically identical (deprecated factory forwards to same case with `annotations: nil, _meta: nil`); deprecation-warning count drops by 3. (#84) Retrofitted 31 of 57 lenient `XCTAssertTrue(script.contains(...))` assertions in `MailControllerComposeTests.swift` to `assertOrdered(script, needle, between:, and:)` — defends against regressions that move a property outside its expected `tell ... end tell` block (which previously passed contains() silently but crashed Mail.app at runtime). Targets compose/createDraft recipient + html content, reply/forward plain + markdown + html branches. Remaining 24 stay lenient with documented rationale (boundary tokens, top-level dispatch verbs, first-occurrence substring collisions). Pure test-tightening; production behavior unaffected. swift test 321/0/8 unchanged.

## [2.8.2] - 2026-05-11

### Added
- **`sanitize_links` hardening grab-bag** ([#87](https://github.com/PsychQuant/che-apple-mail-mcp/issues/87)). Five independent hygiene items from cluster A's verify follow-up triage: (1) allowlist **tripwire** test pinning the exact contents `{http, https, mailto, tel}` — accidental expansion (e.g. adding `vbscript`, `file`, `chrome`) now fails the test immediately rather than silently unblocking schemes; (2) **bypass-class regression tests** for case-mix `JaVaScRiPt:`, `file://`, `vbscript:`, `chrome://`, `blob:`, plus relative + empty URLs — all 6 bypass classes now have explicit assertions; (3) **defense-in-depth `htmlEscape`** wrap on `link.absoluteString` in the rendered anchor `href` attribute — Foundation already percent-encodes, so this is a no-op today but pins the contract that the href value MUST be HTML-safe independent of Foundation behavior; (4) **empty-scheme behavior documented** in all 4 `sanitize_links` schema descriptions (Non-absolute URLs like `[home](/relative/path)` or `[text]()` also have their anchor dropped under sanitize_links=true since they lack an allowlisted scheme) — closes the silent-no-op trap surfaced by cluster A's logic finding L#19a; (5) **payload-scaling latency test** for `attachmentNames` — synthesizes an .emlx with 10×5MB base64 attachments and asserts the names-only walker stays under 1s (measured: ~85ms). Catches the regression class where the walker is swapped back to eager-decode `parseAllParts` — previously the existing 200ms ceiling on the small ASCII fixture wouldn't trip on this class of regression. Zero behavior change for production code; 8 new tests (suite: 313 → 321).

## [2.8.1] - 2026-05-11

### Changed
- **`sanitize_links` schema description consistency across 4 composing tools** ([#86](https://github.com/PsychQuant/che-apple-mail-mcp/issues/86)). Cluster A shipped `sanitize_links` opt-in but only `compose_email`'s schema description carried the XSS rationale; `create_draft`, `reply_email`, `forward_email` had a truncated "Same semantics as compose_email" pointer. LLMs tool-selecting against those 3 schemas couldn't see the security-relevant note. All 4 descriptions now use identical unified text that (a) repeats the XSS rationale (defends against `[click](javascript:...)`, `data:`, `file:`, `vbscript:`), (b) explicitly states "only applies when `format` is `markdown`; no effect in plain/html modes" — preventing the silent-no-op trap where a caller passes `format: "html", sanitize_links: true` and assumes protection. Pure schema text change, zero behavior impact. swift test 313/0/8 unchanged.

## [2.8.0] - 2026-05-11

### Added
- **`sanitize_links` formal spec coverage + builder-layer wiring contract tests** ([#85](https://github.com/PsychQuant/che-apple-mail-mcp/issues/85)). Closes the two P2 verify-followup gaps from cluster A's #19 ship: (Gap B) `openspec/specs/message-composition/spec.md` now has a formal Requirement block "Markdown mode honors opt-in URL scheme allowlist via `sanitize_links`" with Scenarios codifying default-off passthrough, javascript: blocking, allowlist preservation (http/https/mailto/tel), no-op semantics in plain/html modes, and the builder-seam wiring contract; (Gap A) `MailControllerComposeTests` adds wiring contract tests for each composing tool that pin the builder→renderer forwarding, exercising both arms (default-off passes javascript: through + sanitize_links=true blocks it). Verified by fault injection: dropping the `sanitizeLinks` arg from any `build*Script`'s internal `renderBody` call now causes test failure. Coverage scope: the builder→renderer seam where filtering happens. Controller→builder one-line forwarding and schema→handler param parsing remain uncovered without further refactoring (tracked as future hardening if desired).
- **Opt-in `sanitize_links` parameter on all four composing tools** ([#19](https://github.com/PsychQuant/che-apple-mail-mcp/issues/19)). Defends against `[click](javascript:alert('xss'))` and `data:`/`file:`/`vbscript:` URLs in markdown-mode bodies. When `sanitize_links=true`, link URLs whose scheme is not in the allowlist `{http, https, mailto, tel}` render as plain text (no `<a>` wrapper). Default `false` preserves backwards compat — opt-in only because broad mail clients already block `javascript:` URLs and breaking change-by-default would be too aggressive. Plain mode unaffected (no link parsing); html mode is by-design caller-trusted (caller responsible for sanitizing their own raw HTML). 5 new tests: default-off passthrough (regression), `javascript:` blocked, `https://` preserved, `mailto:`/`tel:` preserved, `data:` blocked.

### Fixed
- **AppleScript fallback `extractHTMLBody` now decodes base64 HTML parts** ([#73](https://github.com/PsychQuant/che-apple-mail-mcp/issues/73)). Sister bug to #72: when SQLite cache misses or `EmlxParser.readEmail` throws, `getEmail(format='html')` falls through to `MailController.extractHTMLBody`, which only handled `quoted-printable` content-transfer-encoding. For Android Gmail / Outlook Mobile messages — which commonly use `base64` for the HTML part — this returned raw base64 to the caller. Fix: walk the per-part headers, capture `Content-Transfer-Encoding`, and branch on the value. Both `base64` (with `\r\n`/`\n`/`\r`/space/tab whitespace stripped before `Data(base64Encoded:)`) and `quoted-printable` are decoded; `7bit` / `8bit` / `binary` / unknown values pass through unchanged. Malformed base64 degrades gracefully to raw passthrough rather than crashing.
- **`decodeQuotedPrintable` no longer mojibakes UTF-8 multi-byte sequences** (regression surfaced by #73's tests). Pre-fix code appended each `=XX`-decoded byte as `Character(Unicode.Scalar(byte))`, treating a UTF-8 multi-byte sequence (e.g. `é` = `0xC3 0xA9`) as two separate codepoints `Ã ©` — classic mojibake. Fix: collect all decoded bytes (literal + `=XX`) into a `[UInt8]` buffer, then decode the buffer as UTF-8 once at the end. `extractHTMLBody` was promoted from `private` to internal access so `MailControllerHtmlExtractionTests` can hit the parser directly without spinning up AppleScript — 5 regression tests covering the QP-UTF-8, base64, base64-with-line-wrapping, 7bit-passthrough, and malformed-base64-graceful-degrade scenarios.

## [2.7.2] - 2026-05-10

### Added
- **Attachment count cap (50) in `validateAttachmentPaths`** ([#63](https://github.com/PsychQuant/che-apple-mail-mcp/issues/63)). Caller passing `attachments.count > 50` now throws `MailError.invalidParameter` with a clear "exceeds cap" message. Mitigates DoS amplification: post-#60 each attachment adds ≈0.3s AppleScript dispatch latency + 0.5s trailing drain, so N=1000 would block Mail.app for ≈300s. The 64KB osascript script soft cap already capped practical N to ~200-400 (≈60-120s ceiling), but explicit count cap is cleaner, gives predictable error instead of opaque AppleScript truncation, and matches the input-validation hardening series (#38 / #41 / #50). 50 is well above realistic legitimate use (typical mail attachments ≤ 10) but below the script-size cliff.
- **Env-configurable attachment delays** ([#64](https://github.com/PsychQuant/che-apple-mail-mcp/issues/64)). New env vars `CHE_MAIL_ATTACHMENT_DELAY_BETWEEN` (default 0.3) and `CHE_MAIL_ATTACHMENT_DELAY_TRAILING` (default 0.5) act as escape hatch for the magic constants picked in #60. Defaults are not measured — on a Mac under load (Time Machine, Spotlight reindex, large mail sync) or after Mail.app updates the timing window can shift, leaving users with no way to test calibration without a code change. Sane bounds (0–10s) prevent denial-of-self attacks via accidentally-huge values; out-of-bounds or unparseable values fall back to defaults silently. Also gives diagnostic value: a user reporting "still drops attachments" can be asked to set `CHE_MAIL_ATTACHMENT_DELAY_BETWEEN=1.0` and re-test, providing empirical calibration data before code changes.

### Changed
- **`attachmentFragment` indent normalized across all 3 callers** ([#61](https://github.com/PsychQuant/che-apple-mail-mcp/issues/61), regression of [#39](https://github.com/PsychQuant/che-apple-mail-mcp/issues/39)). Pre-fix, `buildComposeEmailScript` and `buildCreateDraftScript` prefixed attachmentFragment output with `"\n        "` (8 spaces) while `buildReplyEmailScript` (post-#33) used bare `"\n"`. Combined with the helper's own 4-space indent, this produced visually inconsistent emitted scripts — first attachment line at column 12, every subsequent line and trailing delay at column 4. AppleScript ignores leading whitespace so runtime behavior is unchanged; this is purely readability + future-trap hardening. Header comment at `ComposeScriptBuilder.swift:13-20` now spells out the helper-owns-indent contract so the next refactor doesn't drift back.

### Removed
- **Dead helper `MailController.attachmentScript(_:)`** ([#62](https://github.com/PsychQuant/che-apple-mail-mcp/issues/62)). Was lines 776-783, private and orphaned — no callers in the codebase. Emitted the OLD `make new attachment` pattern WITHOUT the #60 race-mitigation delays. The drift risk: a future refactor wiring it back up would silently re-introduce the #60 silent-attachment-drop bug, and #60's verify gate wouldn't catch it (existing unit tests target `ComposeScriptBuilder.attachmentFragment`, not `MailController.attachmentScript`). Canonical fragment helper is `ComposeScriptBuilder.attachmentFragment`.

### Fixed
- **`get_email_metadata` SQLite path now falls back to AppleScript on error** ([#71](https://github.com/PsychQuant/che-apple-mail-mcp/issues/71)). Pre-fix, `Server.swift get_email_metadata` was the only read tool whose SQLite fast path lacked a `do/catch` fallback wrapper — a throw from `reader.getEmailMetadata(messageId:)` (corrupt DB row, schema drift, lock contention during sync) propagated to the caller instead of falling through to the AppleScript path 3 lines below. By contrast, all 7 sister read tools (`get_email`, `get_emails_batch`, `get_email_headers`, `get_email_source`, `save_attachment`, `list_attachments`, `search_emails`) wrap the SQLite call in `do/catch` with stderr log and fallback. Pre-existing inconsistency surfaced during #69 (PR #70) verify by Codex CLI + Devil's Advocate independently. Fix: mirror the canonical pattern from `save_attachment` (#12) — log to stderr `SQLite get_email_metadata fast path failed for rowId=<N>: <error>; falling through to AppleScript` and fall through. README "fallback parity" table updated; EWS / Exchange paragraph now says all 8 read tools (instead of "7 read tools, get_email_metadata is the gap").

## [2.7.1] - 2026-05-09

### Fixed
- **Header/body split returns absolute Data index, slice-safe** ([#72](https://github.com/PsychQuant/che-apple-mail-mcp/issues/72)). Pre-fix, `RFC822Parser.headerBodySplitOffset` and `findDoubleCRLF` used `Array(data)` returning 0-based array indices, but callers (`EmailContent.readEmail` line 75, `EmlxParser.readHeaders` line 140, `AttachmentExtractor` × 2) passed Data slices from `EmlxFormat.extractMessageData` (which has non-zero `startIndex` = byte-count header prefix length) and indexed them as `messageData[bodyOffset...]`. Swift's Data subscript treats integer indices as **absolute** in the parent buffer, so the body slice was `messageData.startIndex` bytes too early — the tail of the final header line bled into the body. For Android Gmail single-part `text/html` + `Content-Transfer-Encoding: base64` messages, the symptom was `html_body == "sion: 1.0\n\n<base64>"` where `sion: 1.0` is the tail of `MIME-Version: 1.0`. Downstream LLM agents then ingested raw base64 in their context and triggered Anthropic AUP false-positives that blocked entire archive-mail pipelines. Fix: iterate over `data.indices` and return absolute Data indices in both functions; `parseHeaders` cleaned up to use the slice-safe `findDoubleCRLF` directly. Plan-tier RED phase caught the wrong initial hypothesis (`parseMultipart` String round-trip) and re-routed to actual root cause within one debug round.
- **`save_attachment` no longer silently writes 0-byte files when only `.partial.emlx` exists** ([#66](https://github.com/PsychQuant/che-apple-mail-mcp/issues/66)). Pre-fix, `EmlxParser.saveAttachment` would happily `data.write(...)` an empty `Data()` and return `"Attachment saved to <path>"` (success) for any IMAP message Apple Mail had stripped to `.partial.emlx` — the MIME structure still declares the attachment via `Content-Disposition: filename`, but the base64 body is empty because the binary lives in the sibling `Attachments/<rowId>/<part_id>/<filename>` cache folder. Confirmed in the wild on 2026-05-04 against an outbound peer-review attachment retrieval (1.75 MB PDF in cache, MCP wrote 0 bytes, no error). Fix: when the matched MIME part has empty `decodedData`, walk `<hashDir>/Attachments/<rowId>/*/<filename>` and prefer the external bytes; if neither inline nor external file exists, throw `attachmentNotFound` so the AppleScript fallback (or the caller) surfaces the failure rather than producing a false success. The 100 MB size guard is applied to the externalised bytes too. Architecturally: the SQLite + .emlx fast path now handles `.partial.emlx` end-to-end; the AppleScript fallback at `Server.swift:1017` is no longer reached for this common pattern.

### Changed
- **SQLite fast-path fallback now logs to stderr instead of failing silently** ([#69](https://github.com/PsychQuant/che-apple-mail-mcp/issues/69), [#70](https://github.com/PsychQuant/che-apple-mail-mcp/issues/70)). Pre-change, when the SQLite + .emlx fast path threw an error (e.g., `.emlx` file missing), `Server.swift:768` for `get_email` (and the parallel `get_email_headers` path at line 1139) silently fell through to the AppleScript fallback with no visibility into why the fast path failed. Made debugging difficult when fast paths regressed. Fix: emit a single stderr line `SQLite get_email fast path failed for rowId=<N>: <error>; falling through to AppleScript` (and parallel for `get_email_headers`) — observable via `claude mcp logs` without changing the response semantics. Mirrors the same logging pattern used by `save_attachment` since v2.6.0.

## [2.7.0] - 2026-05-03

### Fixed
- **Multi-attachment compose / draft / reply no longer silently drops attachments past the first** ([#60](https://github.com/PsychQuant/che-apple-mail-mcp/issues/60)). Pre-fix, every `compose_email` / `create_draft` / `reply_email` call with `attachments.count >= 2` could drop one or more attachments due to a Mail.app AppleScript race: consecutive `make new attachment ... at after the last paragraph` lines resolved to the same anchor before the previous attachment had bound, and `save` / `send` committed before the async attachment pipeline drained. Confirmed in the wild on 2026-05-03 against an outbound onboarding-paperwork reply (3 PDFs requested → 2 attached automatically, third silently dropped; user manually dragged the third file in before sending). Fix: rewrite `attachmentFragment` in `Sources/CheAppleMailMCP/AppleScript/ComposeScriptBuilder.swift` to emit `delay 0.3` between consecutive `make new attachment` lines plus a trailing `delay 0.5` before dispatch. **Latency floor** for `N >= 2`: approximately `(N-1) × 0.3 + 0.5` seconds added per call (3 attachments → ≈1.1 s, 5 attachments → ≈1.7 s). `N == 1` is unchanged — no race at single attachment, no penalty on the common path. Single source of truth: all 3 callers (`buildComposeEmailScript`, `buildCreateDraftScript`, `buildReplyEmailScript`) inherit the fix automatically since they share the helper. `buildForwardEmailScript` is unaffected (does not currently accept attachments).

## [2.6.0] - 2026-05-03

### Fixed
- **`forward_email` plain mode now embeds quoted original message in the forwarded body** ([#44](https://github.com/PsychQuant/che-apple-mail-mcp/issues/44)). Same root cause as #43 (which fixed `reply_email`): AppleScript `& content` against a freshly-created outgoing message returns empty before Mail.app's GUI populates the quoted body, so every plain `forward_email` since `b8a4a89` (initial release) silently dropped the quoted original. Fix: lift the `if format != .plain` pre-fetch gate so `originalPlain` is always fetched (when a body is provided), wrapped in `try/catch` for graceful degrade; refactor plain branch in `buildForwardEmailScript` to use the existing `composeReplyPlainText` helper from #43 (reuses RFC 3676 `> ` prefix + CRLF normalization + trim + empty-line `>` stuffing). The HTML branch was already correct (uses `composeReplyHTML` + `<blockquote>`). **Wire-output behavioral change**: every plain-format `forward_email` body with a user-provided body now reads `<user body>\n\n> <quoted lines>` instead of just `<user body>`. Forward without body is unchanged (no quote block, no body mutation). The `forward_email` tool description updated accordingly.
- **Boolean and array tool parameters now hard-fail on type mismatch instead of silently coercing** ([#35](https://github.com/PsychQuant/che-apple-mail-mcp/issues/35)). Pre-fix, `arguments["save_as_draft"]?.boolValue ?? false` would silently treat string `"true"` (mistakenly emitted by an LLM caller) as `false` — the user wanted "save for review" but got "send now", irreversible. Same class for `cc_additional` / `attachments` (string instead of array → silent nil → recipient missing CC). Fix: new `Server.swift` helpers `requireBool(_:key:default:)` and `optionalStringArray(_:key:)` use case-pattern matching to require literal `Bool` / `[String]` types in the JSON. Throws `MailError.invalidParameter` with key name + expected vs actual type for clear LLM caller self-correction. Applied to `reply_email` (4 params: `reply_all`, `cc_additional`, `attachments`, `save_as_draft`), `compose_email` (3 params: `cc`, `bcc`, `attachments`), `create_draft` (`attachments`).
- **Email addresses now validated at recipient field boundaries** ([#41](https://github.com/PsychQuant/che-apple-mail-mcp/issues/41)). New `validateEmailAddresses(_:field:)` helper rejects: control characters (header injection vector — `\n`, `\r`, `\t`, NULL, 0x00-0x1F, 0x7F), missing/multiple `@`, `@` at start/end. Applied to `to`/`cc`/`bcc` in `compose_email`, `to` in `create_draft`/`forward_email`, and `cc_additional` in `reply_email`. Errors collect ALL failures with the field name so callers can self-correct on retry without one-at-a-time iteration.
- **`reply_email` `cc_additional` now de-duplicates case-insensitively** ([#34](https://github.com/PsychQuant/che-apple-mail-mcp/issues/34)). Pre-fix, `["a@b.com", "A@B.COM"]` would emit two `make new cc recipient` AppleScript calls — Mail.app is not idempotent-by-address. New `dedupAddresses(_:)` helper preserves first-seen order. **Limitation**: cross-list dedup against `reply_all`-derived CCs from the original message is not yet implemented (would require fetching original CC headers); tracked for future enhancement.
- **Attachment paths now validated against a deny-list of sensitive directories** ([#38](https://github.com/PsychQuant/che-apple-mail-mcp/issues/38)). Pre-fix, `compose_email` / `create_draft` / `reply_email` only checked file existence, so a malicious / hallucinated MCP caller could pass `attachments=["~/.ssh/id_ed25519"]` and have it silently attached. The pre-existing surface since v0.x was made worse by #33's `save_as_draft=true` (silent draft staging without GUI popup). Fix: new `validateAttachmentPaths` helper checks (a) existence, (b) symlink resolution before deny-list (defeats `~/Documents/decoy → ~/.ssh` bypass), (c) hardcoded deny-list of `~/.ssh`, `~/Library/Keychains`, `~/Library/Application Support/com.apple.TCC`, `~/Library/Cookies`, browser cookie/state directories, `/etc`, `/var`, `/private`. Replaces `validateFilePaths` at all 3 call sites.
- **`id` parameter on all 17 message-id-taking tools is now hard-validated as Int at the handler boundary** ([#50](https://github.com/PsychQuant/che-apple-mail-mcp/issues/50)). Pre-fix, `id` was passed unescaped into AppleScript `whose id is \(id)` interpolation. A crafted `id = "123 whose subject is \"x\" or true ..."` would cause Mail.app to return the wrong message via predicate short-circuit (`or true`). The pre-existing surface since `b8a4a89` (initial release) was made worse by #43 (every `replyEmail` now does 2 AppleScript round-trips, both using the same unescaped id). Fix: new `Server.swift` helper `requireMessageId(_:)` rejects missing / empty / non-string / non-numeric input with `MailError.invalidParameter` at the handler boundary; `MailController.msgRef` adds a debug-only `assert` as defense in depth. The `id: string` JSON Schema is unchanged (no breaking change for MCP callers; runtime validation is strictly stronger).

### Added
- **`MAIL_MCP_ATTACHMENT_ROOTS` env var** — colon-separated allow-list of root directories. When set, attachment paths must resolve under one of these roots (after symlink resolution); when unset (default), only the deny-list applies. For security-conscious deployments: `MAIL_MCP_ATTACHMENT_ROOTS=~/Documents/letters:~/Downloads/safe-attach`.

### Security
- [`SECURITY.md`](SECURITY.md) extended with `id` validation contract section (#50) — adds to the existing threat model, attachment path policy, and RFC 3676 nested quote forgery known limitation.

### Tests
- **Schema tests now assert type annotations not just key presence** ([#42](https://github.com/PsychQuant/che-apple-mail-mcp/issues/42)). New `assertSchemaProperty(_:key:hasType:itemsType:)` helper validates `.type` and (for arrays) `.items.type`. Catches accidental drop of type annotation during refactors. Applied to `reply_email` and `compose_email` schemas (full audit of remaining tools deferred — pattern is now ready for trivial application).

## [2.5.0] - 2026-05-03

### Fixed
- **`reply_email` plain mode now embeds quoted original message in the draft body** ([#43](https://github.com/PsychQuant/che-apple-mail-mcp/issues/43)). Pre-fix every plain-format `reply_email` call since `b8a4a89` (initial release) silently produced bare-body replies because the AppleScript `set content to "<body>" & return & return & content` pattern read the outgoing message's `content` property as empty — Mail.app does not populate the quoted body until the GUI compose pipeline materializes it (especially when `without opening window` is used for `save_as_draft=true`). Fix: pre-fetch the original content unconditionally and Swift-side compose RFC 3676 `> `-prefixed quoted body via a new `composeReplyPlainText` helper. The HTML branch was already correct (it always pre-fetched and built `<blockquote>`). **Wire-output behavioral change**: every plain-format reply body now reads `<user reply>\n\n> <each line of original>` instead of just `<user reply>`. Round-1 verify hardening: CRLF/CR normalization, trailing-newline trim, empty-line `>` stuffing per RFC 3676 §4.5, and graceful degrade when pre-fetch fails (sandbox / deleted message → "no quote" rather than abort).

### Changed
- **`reply_email` MCP tool description and `format` parameter description updated** to document the new RFC 3676 quoted-body behavior for plain mode. The previous wording ("preserves existing concatenation semantics") was misleading because the underlying behavior was broken; the new wording reflects what the tool actually does.
- **`openspec/specs/message-composition/spec.md` Scenario "Reply in plain mode"** rewritten from `"Thanks\n\n<original plain content>"` to RFC 3676 quoted form, with a `> ` prefix on every original line and `>` (no trailing space) on empty lines.

## [2.4.1] - 2026-05-02

### Fixed
- **`reply_email` `save_as_draft=true` no longer pops Mail.app reply window** ([#33 verify finding A](https://github.com/PsychQuant/che-apple-mail-mcp/issues/33)). Previously the AppleScript used `with opening window` unconditionally, which pops the GUI even when the caller asked for a quiet draft. User edits the popup, closes-without-save → the version in Drafts is the pre-edit snapshot, silently stale. Fix: branch on `saveAsDraft` and use `without opening window` when saving as draft; keep `with opening window` for the send path (backward compat).
- **`reply_email` now validates attachment paths up-front** ([#33 verify finding B](https://github.com/PsychQuant/che-apple-mail-mcp/issues/33), Codex finding). `composeEmail` (line 656) and `createDraft` (line 739) already call `validateFilePaths(attachments)`. `replyEmail` was missing the same call, so an invalid path would error inside the `tell replyMsg` block AFTER `set content` and CC fragments had executed — leaving the user with a polluted half-open reply window and no draft. Fix: mirror the call at the top of `replyEmail`.

## [2.4.0] - 2026-05-02

### Added
- **`reply_email` reply-as-draft mode** with `cc_additional`, `attachments`, `save_as_draft` optional params ([#33](https://github.com/PsychQuant/che-apple-mail-mcp/issues/33)). Closes the gap where `reply_email` could preserve a thread but not save as draft / add CC / add attachments, while `create_draft` could save + attach but not stay in the original thread. Workflow this unblocks: reply to an existing thread + add extra CC + attach files + save as draft for human review before sending. AppleScript implementation reuses existing `recipientFragment` and `attachmentFragment` helpers; conditional `save replyMsg` vs `send replyMsg` based on `save_as_draft`. Both plain and html branches updated symmetrically. Backward compatible — defaults preserve existing send-immediate behavior. 6 new tests (1 schema test + 5 compose tests covering cc, attachments, save vs send, backward compat, html branch parity).

### Fixed
- **`list_attachments` now cross-validates SQLite metadata against on-disk `.emlx` contents** ([#24](https://github.com/PsychQuant/che-apple-mail-mcp/issues/24)). Previously, the SQLite `attachments` table could surface stale entries — Mail.app keeps the row even after the IMAP binary is stripped on Sent / lazy-loaded — and `save_attachment` would then fail with `Attachment not found`. The handler now calls a new `EmlxParser.attachmentNames(rowId:mailboxURL:)` helper that walks the `.emlx` MIME tree, and filters SQLite results to names actually present. On `.emlx` resolve / parse failure, falls back to raw SQLite metadata (≥ pre-fix behavior) and logs the cause to stderr.

### Performance
- **`list_attachments` no longer eager-decodes attachment binaries during cross-validation** (verify finding for [#24](https://github.com/PsychQuant/che-apple-mail-mcp/issues/24)). The initial fix used `MIMEParser.parseAllParts`, which decodes every part's body (including base64 attachments) just to read the filenames — a 50 MB attachment caused list_attachments to allocate ≈50 MB of decoded data the caller never reads. Now uses a new `MIMEParser.enumerateAttachmentNames(_:headers:)` walker that visits MIME tree headers but skips `decodeTransferEncoding` on leaves. Complexity drops from O(message size) to O(message structure size), independent of attachment payload sizes. Honors the same `maxMultipartDepth=8` guard.

### Added (v2.4.0 ancillary)
- **`EmlxParser.attachmentNames(rowId:mailboxURL:) -> Set<String>`** — new helper that returns the union of `Content-Disposition: filename` (RFC 2231/5987 decoded) and `Content-Type: name` parameter values across all MIME parts. Used by the `list_attachments` cross-validation path; also available to future callers that need to enumerate attachment names without writing any to disk.
- **`MIMEParser.enumerateAttachmentNames(_:headers:) -> Set<String>`** — names-only MIME tree traversal. Faster + lower-memory alternative to `parseAllParts` when the caller only needs filenames (skips transfer decoding). 4 regression tests including a names-only invariant test (synthesizes a multipart with invalid base64 body, asserts filename still extractable — proves no decode path is taken).

## [2.3.0] - 2026-04-17

### Added
- **`format` parameter on four composing tools** (`compose_email`, `create_draft`, `reply_email`, `forward_email`) — resolves [#15](https://github.com/PsychQuant/che-apple-mail-mcp/issues/15) (P0) and [#14](https://github.com/PsychQuant/che-apple-mail-mcp/issues/14). Accepts `"plain"` (default, fully backwards-compatible), `"markdown"`, or `"html"`. `"markdown"` renders bold / italic / inline code / links / lists / multi-paragraph via Swift-native `AttributedString(markdown:)` with a custom HTML emitter (direct run walk with `PresentationIntent` identity-based block boundaries, not `NSAttributedString → .html`, which drops inline presentation intents). `"html"` passes body verbatim into Mail.app's AppleScript `html content` property.
- **Reply / forward blockquote merge semantics**: in `"markdown"` / `"html"` mode, the user body is composed as HTML and the original message is wrapped in `<blockquote>…</blockquote>` beneath an `<hr>` separator. In practice, the original's HTML is HTML-escaped plain text because Apple's AppleScript interface denies read access to `html content` on current macOS (empirically confirmed error -1728/-1723). See [#18](https://github.com/PsychQuant/che-apple-mail-mcp/issues/18) for architectural follow-up on full rich-text preservation.
- **New `message-composition` capability spec** at `openspec/specs/message-composition/spec.md` — first formal spec covering all four composing tools' input schemas, format semantics, reply/forward merge rules, and the AppleScript `html content` read-denial limitation.
- **`Sources/CheAppleMailMCP/MarkdownRendering.swift`** — new helper module exposing `BodyFormat`, `ComposedBody`, `renderBody(_:format:)`, and `htmlEscape(_:)`. Zero new Swift Package dependencies.
- **`Sources/CheAppleMailMCP/AppleScript/ComposeScriptBuilder.swift`** — extracted nonisolated script builders for all four composing tools, making script output unit-testable without executing Mail.app.
- **New unit-test suites** introduced: `MarkdownRenderingTests` (markdown parser behavior), `BodyFormatTests` (parameter type parsing), `MailControllerComposeTests` (script-builder output), `ServerSchemaTests` (tool-schema invariants + `parseBodyFormatArgument` validation). [Note: original entry stated specific counts that drifted from reality as later releases added tests to these files; counts removed to prevent rot. Current counts: `swift test` reports them in the run output.]
- **4 integration tests** in `MailAppIntegrationTests` (gated by `MAIL_APP_INTEGRATION_TESTS=1`) that create real drafts in Mail.app, confirm `html content` write succeeds, and assert the inbox read-denial behavior — produces the spec's empirical ground truth.

### Changed
- **`MailController.composeEmail` / `createDraft` / `replyEmail` / `forwardEmail` signatures** gain an optional trailing `format: BodyFormat = .plain` parameter. All existing call sites compile unchanged; default `.plain` preserves current AppleScript `content:` behavior.
- **`CheAppleMailMCPServer.defineTools()`** widened from `private` to module-internal visibility to enable schema round-trip tests.
- **Tool descriptions** for all four composing tools updated to advertise the `format` parameter and its semantics.

### Fixed
- **Multi-paragraph markdown now renders as distinct `<p>` tags** ([#15 verify finding](https://github.com/PsychQuant/che-apple-mail-mcp/issues/15#issuecomment-4263936896)). Previously, `"Para 1.\n\nPara 2."` merged into `<p>Para 1.Para 2.</p>` because `attributedStringToHTML` used only `BlockKind` enum equality to detect block boundaries; adjacent paragraphs share the same `BlockKind.paragraph` value. Fix: flush the buffer on any `PresentationIntent` change (identity-aware), not only on `BlockKind` change. Same root cause affected adjacent markdown list items (`- a\n- b` collapsed into single `<li>`); now correctly produces multiple `<li>` elements per list.
- **Non-string `format` argument no longer silently falls back to plain** ([#15 verify finding](https://github.com/PsychQuant/che-apple-mail-mcp/issues/15#issuecomment-4263936896)). `format: 42` or `format: true` previously returned `.plain` because `Value.stringValue` returned nil for non-`.string` cases. New `parseBodyFormatArgument(Value?)` distinguishes `nil` / `.null` (→ `.plain`, backwards compat) from present-but-wrong-type (→ `MailError.invalidParameter`).

### Non-Goals (deferred to follow-up issues)
- **Signature preservation in non-plain modes** ([#18](https://github.com/PsychQuant/che-apple-mail-mcp/issues/18)): the system overwrites `html content` wholesale in markdown/html mode, losing Mail.app's auto-inserted signature. Apple's AppleScript denies read access that would let us preserve it. Full preservation requires a MailKit extension (architectural follow-up).
- **Nested markdown lists** ([#16](https://github.com/PsychQuant/che-apple-mail-mcp/issues/16)): `- outer\n  - inner` collapses to a single list item. `assembleBlocks` needs stack-based list tracking.
- **Markdown tables** ([#17](https://github.com/PsychQuant/che-apple-mail-mcp/issues/17)): silently concatenate row cells; currently not in the supported subset.
- **Link URL sanitization** ([#19](https://github.com/PsychQuant/che-apple-mail-mcp/issues/19)): `[x](javascript:...)` passes through unchanged. Documented as "caller responsibility" but an opt-in sanitizer is a reasonable follow-up.
- **Misc hardening** ([#20](https://github.com/PsychQuant/che-apple-mail-mcp/issues/20), [#21](https://github.com/PsychQuant/che-apple-mail-mcp/issues/21), [#22](https://github.com/PsychQuant/che-apple-mail-mcp/issues/22)): test quality (lenient `contains` assertions), tool description caveats about HTML read denial, attachment-line indentation parity, U+001E edge cases, bold-inside-link AttributedString limitation, fenced code block language tag.

### Verification
6-way review (`/idd-verify #15`): Claude Explore agent + Claude self-review 5 lens + Codex CLI (gpt-5.4 xhigh, independent model) + Devil's Advocate adversarial agent. 20+ findings merged & deduped; 2 P1s fixed in-scope, 12 follow-ups routed to issues #16-#22. Spec + design analyzer clean, validator ✓. 214 tests pass / 5 skipped / 0 failures.

### Spec
- New capability `message-composition` with 8 Requirements covering format parameter, plain/markdown/html semantics, reply/forward blockquote, signature out-of-scope, and AppleScript html-content read denial (empirically-grounded).

## [2.2.0] - 2026-04-14

### Performance
- **`save_attachment` is now 10–100× faster** ([#12](https://github.com/PsychQuant/che-apple-mail-mcp/issues/12)). The previous implementation went through AppleScript IPC (`tell Mail.app to save att in POSIX file ...`), taking 1–3 seconds per attachment. The new fast path reads the `.emlx` file directly, parses the MIME multipart structure, decodes the matching part, and writes it — all in-memory — for sub-50 ms latency. Bulk operations (e.g., `/archive-mail` attachment backfill) drop from ~30 s to under 1 s for 14 attachments.

### Added
- **`MIMEParser.parseAllParts(_:headers:) -> [MIMEPart]`** — a non-lossy MIME enumeration API that walks the multipart tree and returns every part (text, html, attachments, inline images, nested multipart). Complements (does not replace) the existing `parseBody` text-extraction API. The new API is hardened against multipart bombs with a depth limit of 8.
- **`MIMEPart` struct** in `Sources/MailSQLite/MIMEPart.swift` — a `Sendable`, `Equatable` value type that carries `headers`, `contentType`, `contentTypeParams`, `contentDisposition`, `filename`, `rawBytes`, and eagerly-decoded `decodedData` for each part. Filename resolution honors RFC 2231 / RFC 5987 continuation encoding and percent-decoded UTF-8 (so Exchange / Gmail CJK filenames work).
- **`EmlxParser.saveAttachment(rowId:mailboxURL:attachmentName:destination:)`** in `Sources/MailSQLite/AttachmentExtractor.swift` — direct-from-filesystem attachment extraction. Resolves `.emlx` path via the existing `mailStoragePathOverride` test hook (#9), strips the Apple wrapper, walks all MIME parts, finds first match by filename (first-match semantics), and writes `decodedData.write(to: destination, options: .atomic)`.
- **Typed errors**: `MailSQLiteError.attachmentNotFound(name:)` and `MailSQLiteError.attachmentTooLarge(name:size:limit:)` so the dispatcher can distinguish fallback triggers.
- **26 new tests** (156 total now, was 130): 6 for `MIMEPart`, 13 for `MIMEParser.parseAllParts` + filename decoding, 7 for `AttachmentExtractor` end-to-end with fixture `.emlx` files.
- **4 fixture files** in `Tests/MailSQLiteTests/Fixtures/`: ASCII attachment, CJK filename (RFC 5987), nested multipart, duplicate filename. Plus expected-payload `.bin` files for byte-level assertion.

### Changed
- **`save_attachment` MCP tool dispatcher** (`Server.swift:939`) now uses a **two-tier catch** pattern matching `get_email`'s precedent: SQLite + `.emlx` fast path runs in its own `do/catch`; any thrown error falls through to the legacy `MailController.saveAttachment` AppleScript call. The two `do/catch` blocks are intentionally **not** collapsed into one — that mistake caused `#9`'s `get_emails_batch` regression and we explicitly avoid it here. The fallback path logs the cause to stderr (`SQLite save_attachment fast path failed: ..., falling through to AppleScript`) so silent fallbacks are observable in production.
- **`MIMEParser.parseBody` is unchanged** — preserved as the hot path used by `get_email` / `list_emails`. The two parallel APIs are cross-verified by `testParseAllPartsAndParseBodyAgreeOnTextBody`.

### Non-Goals (deferred)
- **Streaming / `FileHandle` pipeline**: out of scope. The fast path is in-memory only. Attachments larger than 100 MB throw `attachmentTooLarge`, which the dispatcher catches and falls through to the AppleScript path (Mail.app handles streaming write internally). 99% of real attachments are well under this limit.
- **Inline image `cid:` resolution**: `save_attachment` writes part bytes, not HTML rewrites. Inline images with filenames are still saveable, but `<img src="cid:...">` references in HTML body are unchanged.
- **Exotic transfer encodings** (`uuencode`, `binhex`): unsupported on the fast path; falls through to AppleScript.
- **GitHub Actions automation** for releases: still tracked under [#13](https://github.com/PsychQuant/che-apple-mail-mcp/issues/13). For now, releases are published via `./scripts/release.sh`.

### Spec
- **`emlx-parser` capability** gains a new `Attachment extraction from emlx` requirement with 6 scenarios (ASCII PDF, CJK filename, fallback on throw, first-match duplicate, parseAllParts ⇄ parseBody consistency, large-attachment size-based fallback). See `openspec/changes/save-attachment-fast-path/specs/emlx-parser/spec.md`.

---

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
