import Foundation

func appleScriptEscape(_ string: String) -> String {
    return string
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r\n", with: "\" & return & \"")
        .replacingOccurrences(of: "\n", with: "\" & return & \"")
        .replacingOccurrences(of: "\r", with: "\" & return & \"")
        .replacingOccurrences(of: "\t", with: "\" & tab & \"")
}

// Issue #39 / #61: helper-owns-indent contract.
// `attachmentFragment` and `recipientFragment` emit lines with their own
// 4-space indent baked in. Callers MUST prefix with bare "\n" (newline only,
// no extra spaces) — the helper output already has the indent. Adding
// extra prefix at call sites breaks visual alignment between first line
// (caller-prefix + helper-indent = double-indented) and subsequent lines
// (separator-only + helper-indent = single-indented), regressing #39's
// single-source-of-truth promise.
//
// Issue #60: Mail.app's AppleScript attachment pipeline is asynchronous.
// Two failure modes when emitting consecutive `make new attachment` calls
// without pacing: (1) `at after the last paragraph` in the next call
// resolves to the same anchor as the previous one because the previous
// insert hasn't materialized yet — Mail.app's collision behavior drops
// all but one; (2) `save` / `send` commits before in-flight attachment
// binds drain. For N >= 2 we interleave `delay 0.3` between attachments
// (gives anchor materialization time) and append `delay 0.5` trailing
// (ensures pipeline drain before dispatch). N == 1 has no race so emits
// no delay — keeps the common path latency-free.

// Issue #64: delay constants are escape-hatchable via env vars.
// Defaults (0.3 / 0.5) are picked rather than measured; on a Mac under load
// (Time Machine, Spotlight reindex, dozen apps) or after Mail.app updates
// the timing window can shift. Without an escape hatch, a user reporting
// "still drops attachments 6 months from now" has no way to test calibration
// without a code change. Sane bounds (0–10s) prevent denial-of-self attacks.
private let defaultDelayBetween = 0.3
private let defaultDelayTrailing = 0.5

private func resolvedDelay(envKey: String, fallback: Double) -> Double {
    guard let raw = ProcessInfo.processInfo.environment[envKey],
          let value = Double(raw),
          value >= 0, value <= 10 else {
        return fallback
    }
    return value
}

private func attachmentFragment(for paths: [String]) -> String {
    guard !paths.isEmpty else { return "" }
    let lines = paths.map { path in
        "    make new attachment with properties {file name:POSIX file \"\(appleScriptEscape(path))\"} at after the last paragraph"
    }
    if paths.count == 1 {
        return lines[0]
    }
    let between = resolvedDelay(envKey: "CHE_MAIL_ATTACHMENT_DELAY_BETWEEN", fallback: defaultDelayBetween)
    let trailing = resolvedDelay(envKey: "CHE_MAIL_ATTACHMENT_DELAY_TRAILING", fallback: defaultDelayTrailing)
    var pieces: [String] = []
    for (idx, line) in lines.enumerated() {
        pieces.append(line)
        if idx < lines.count - 1 {
            pieces.append("    delay \(between)")
        }
    }
    pieces.append("    delay \(trailing)")
    return pieces.joined(separator: "\n")
}

// #251: internal (not private) so RecipientDisplayNameTests can pin the
// name-aware output directly. A `Name <email>` recipient becomes the native
// {name, address} property pair — Mail displays the person's name; a bare
// address keeps the historical single-property form byte-identical.
func recipientFragment(_ addresses: [String], kind: String) -> String {
    addresses.map { addr in
        let parsed = parseRecipient(addr)
        if let name = parsed.name {
            return "    make new \(kind) recipient at end of \(kind) recipients "
                + "with properties {name:\"\(appleScriptEscape(name))\", "
                + "address:\"\(appleScriptEscape(parsed.address))\"}"
        }
        return "    make new \(kind) recipient at end of \(kind) recipients with properties {address:\"\(appleScriptEscape(parsed.address))\"}"
    }.joined(separator: "\n")
}

// MARK: - #175 mailto-based clean-body compose (GUI orchestration)
//
// Builds the AppleScript that drives Mail's NATIVE compose pipeline via a
// `mailto:` hand-off (which, unlike `set content` / `set html content`, does NOT
// wrap the body in `Apple-Mail-URLShareWrapperClass` / `blockquote type="cite"`).
// The mailto window is NOT an AppleScript `outgoing message` object, so save/send
// and attachments are driven by System Events keystrokes.
//
// Locale-independence (avoids the #174-class hardcoded-string trap): EVERY step
// uses a keyboard SHORTCUT, never a localized menu-item name —
//   ⇧⌘A = File ▸ Attach,  ⇧⌘G = Go to folder,  ⌘S = save draft,  ⇧⌘D = send.
// These are identical across UI languages.
//
// Robustness (hardened per two #175 verify rounds — DA + Codex cross-model):
//   - WINDOW IDENTITY: before EVERY keystroke phase (each attach AND dispatch) we
//     re-locate the compose window BY TITLE (= subject; eligibility guarantees a
//     non-empty subject) and best-effort raise it, so a keystroke lands on OUR
//     window and not one the user opened/focused during a delay. A bare
//     window-count delta is NOT enough (`activate` can open a viewer). RESIDUAL
//     (documented): AX has no "send keystroke to a specific window" primitive, so
//     a TOCTOU gap between raise and keystroke remains — inherent to GUI
//     automation; a detectable mismatch (our window gone) hard-errors → fallback.
//   - ATTACHMENT COMPLETION: the pre-dispatch check asserts `count of sheets of
//     _w is 0`, so a still-open File▸Attach panel blocks dispatch; a drain delay
//     gives the attachment time to bind before ⇧⌘D. RESIDUAL: panel-closed is a
//     proxy for bind, not per-file completion polling.
//   - STAGE-AWARE FALLBACK + NO DATA LOSS: the GUI interaction is wrapped in
//     try/on-error that closes ONLY a window we created — identified by NEW
//     `id of window` (captured before the mailto) AND matching subject — so a
//     pre-existing same-titled draft the user already had open is never
//     `saving no` discarded (a data-loss bug the second verify round caught).
//     Dispatch is the last statement, so a pre-dispatch error means nothing was
//     sent (fallback safe; no double-send).
//   - CLIPBOARD: the per-attachment path is set on the clipboard here, but
//     save/restore is done by the caller in Swift (full-fidelity NSPasteboard,
//     failure-safe) — this script does NOT save/restore.
// Delays are env-overridable (#64 pattern) because GUI timing drifts under load.

// #218: the GUI dispatch keystroke is shared between the mailto compose path
// (#175) and the native-verb reply/forward paste path. Locale-independent
// shortcuts: ⇧⌘D = send, ⌘S = save draft. Extracted so both paths emit
// byte-identical dispatch (and a single place to change it).
func composeDispatchKeystroke(send: Bool) -> String {
    return send
        ? "keystroke \"d\" using {command down, shift down}"
        : "keystroke \"s\" using command down"
}

func buildMailtoComposeScript(
    url: String,
    subject: String,
    attachments: [String],
    send: Bool,
    fromAddress: String? = nil,
    fillToRecipients: [String] = []
) -> String {
    let windowDelay = resolvedDelay(envKey: "CHE_MAIL_MAILTO_WINDOW_DELAY", fallback: 1.8)
    let stepDelay = resolvedDelay(envKey: "CHE_MAIL_MAILTO_STEP_DELAY", fallback: 0.7)
    let attachDrain = resolvedDelay(envKey: "CHE_MAIL_MAILTO_ATTACH_DRAIN", fallback: 1.5)
    let dispatchKey = composeDispatchKeystroke(send: send)
    let dispatchLabel = send
        ? "Email sent successfully (mailto path)"
        : "Draft created successfully (mailto path)"
    let subjEsc = appleScriptEscape(subject)

    // raiseOnly (runs inside `tell process "Mail"`): re-locate the compose window
    // BY TITLE (= subject) and best-effort raise it so the NEXT keystroke lands on
    // OUR window. Re-applied before EVERY keystroke phase (each attach + dispatch)
    // — focus the user/system stole during a delay is reclaimed. Hard-errors if
    // our window is gone (→ safe fallback). Keys off the target `_w`, never
    // `front window` (that evaluated unreliably under the actor's in-process
    // NSAppleScript context and regressed the path to always-fallback); AXRaise is
    // best-effort (wrapped) so an AX quirk can't break the path.
    let raiseOnly = """
                set _t to "\(subjEsc)"
                set _w to missing value
                set _wMatches to 0
                repeat with _cand in windows
                    if title of _cand is _t then
                        set _w to _cand
                        set _wMatches to _wMatches + 1
                    end if
                end repeat
                if _w is missing value then error "mailto compose window not found (title)"
                if _wMatches > 1 then error "AMBIGUOUS: more than one window is titled the subject — cannot safely target our compose window for the next keystroke (safe fallback)"
                try
                    perform action "AXRaise" of _w
                end try
                delay 0.25
    """
    // verifyNoSheet: raiseOnly + assert no open sheet (the File▸Attach panel must
    // have closed) — used immediately before dispatch.
    let verifyNoSheet = raiseOnly + """

                if (count of sheets of _w) is not 0 then error "a sheet/panel is still open on the compose window"
    """

    // #242 verify hardening (Codex HIGH + DA): `_dispatched` guards the tail —
    // the post-dispatch `delay` runs ONLY on the success path (mail definitely
    // sent), so an error there must be sentinel-marked too, not just keystroke
    // errors. Flag initialized BEFORE the outer try so the handler can always
    // reference it.
    let flagInit = send ? "set _dispatched to false\n    " : ""

    // 1. Capture Mail window ids BEFORE the mailto, hand it off, then identify
    // OUR compose window as the NEW window (id unseen before) whose title is our
    // subject — captured as `_ourId`. On-error cleanup closes ONLY `_ourId`, by
    // id-iteration — never by a title guess, so it can never discard a user's
    // same-titled draft (`saving no` on the wrong window would be data loss —
    // #175 verify R2 + #219/#277 verify R2, Codex BLOCKING). `id of window` is
    // stable + unique. We do NOT assume exactly one new window: launching Mail
    // from closed opens the viewer too, so we pick the new window by subject
    // rather than a count==1 assertion (which would over-reject to legacy
    // whenever Mail wasn't already running).
    // #219/#277 verify (Codex BLOCKING): System Events (where raiseOnly runs)
    // cannot read Mail's window `id`, so the KEYSTROKE-targeting bridge is the
    // title (= subject). Two guards make that bridge sound: (i) refuse the clean
    // path if our subject already titled a window BEFORE the mailto (below), and
    // (ii) raiseOnly asserts EXACTLY ONE window carries our title before each
    // keystroke phase — a same-title window opening concurrently (after the
    // snapshot) makes raiseOnly error pre-dispatch → cleanup closes only `_ourId`
    // → legacy fallback, so a race can neither keystroke/dispatch the wrong
    // window nor lose the user's window. The `my senderMatches` handler is
    // prepended only when a sender popup is driven — see below. It matches the
    // requested addr against a popup label by (a) exact bare addr, (b) the
    // literal `<addr>` angle-addr suffix, or (c) the LAST space-delimited token
    // equalling the addr. #219 live-smoke R6 (Codex/Claude verify all assumed a
    // `Name <addr>` format) found Mail's From popup actually renders
    // `Display Name – addr` with a SPACE + EN DASH (U+2013) + SPACE separator —
    // no angle brackets — so (a)/(b) never matched and the clean path always
    // fell to legacy. Branch (c) is separator-agnostic (en-dash / hyphen / any)
    // and anti-spoof-safe: `isSimpleAddrSpec` gates the addr to no-whitespace
    // upstream, so a simple addr is always the final space-delimited token, and
    // the compare is exact `is` (a `… – notche@x` label's last token is
    // `notche@x` ≠ `che@x`), never a substring. Never extracts between < and >
    // (a quoted local-part could spoof that).
    let senderMatchHandler = (fromAddress?.isEmpty == false) ? """
    on senderMatches(_label, _addr)
        set _label to _label as text
        if _label is _addr then return true
        if _label ends with ("<" & _addr & ">") then return true
        set _tid to AppleScript's text item delimiters
        set AppleScript's text item delimiters to space
        set _parts to text items of _label
        set AppleScript's text item delimiters to _tid
        if (count of _parts) is greater than 0 then
            if (item -1 of _parts) is _addr then return true
        end if
        return false
    end senderMatches

    """ : ""
    var s = senderMatchHandler + """
    tell application "Mail"
        set _wc to (count of windows)
        set _beforeIds to (id of every window)
        set _beforeTitles to (name of every window)
        activate
        mailto "\(appleScriptEscape(url))"
    end tell
    delay \(windowDelay)
    tell application "Mail"
        if (count of windows) <= _wc then error "mailto did not open a compose window"
        if _beforeTitles contains "\(subjEsc)" then error "a window titled \\"\(subjEsc)\\" already existed before this compose — cannot safely disambiguate the new window (safe fallback)"
        set _ourId to missing value
        set _ourMatches to 0
        repeat with _cw in windows
            try
                if (_beforeIds does not contain (id of _cw)) and ((name of _cw) is "\(subjEsc)") then
                    set _ourId to (id of _cw)
                    set _ourMatches to _ourMatches + 1
                end if
            end try
        end repeat
        if _ourMatches is 0 then error "could not identify our new compose window by subject after mailto (safe fallback)"
        if _ourMatches > 1 then error "more than one new window is titled the subject — cannot safely identify our compose window (safe fallback)"
    end tell
    \(flagInit)try
        tell application "System Events"
            tell process "Mail"
                set frontmost to true
    \(raiseOnly)
            end tell
        end tell
    """

    // 1.5 (#277): display-name recipient fill via clipboard paste — TO ONLY.
    // The mailto URL omits any display-name-carrying To list (a name can't ride
    // RFC 6068; pasting `Name <addr>` lets Mail tokenize natively). A fresh
    // compose window focuses the To field by default, so the fill pastes into
    // it and tabs to tokenize. Paste, not keystroke: CJK names via keystroke
    // hit IME nondeterminism (#220 lesson); the Swift caller wraps the run in
    // withClipboardPreserved.
    //
    // Cc is DELIBERATELY not filled here (#277 verify, Codex BLOCKING): Mail's
    // Cc field can be hidden via Header Fields, so a Tab-to-Cc + paste would
    // silently land in Subject/elsewhere and the draft would save with NO Cc
    // (silent recipient loss). To is always visible + default-focused; Cc is
    // not reliably targetable. So display-name Cc keeps the LEGACY path (which
    // sets Cc names natively) — enforced by eligibility (displayNameFillViable
    // requires a display-name-free cc). Any window-identity failure errors out
    // pre-dispatch → cleanup closes OUR new window → legacy fallback.
    // Draft-only by design (#277): send:true never reaches this phase — a
    // failed fill on a send would fire with missing recipients.
    if !fillToRecipients.isEmpty {
        let toLine = fillToRecipients.joined(separator: ", ")
        s += """

        set the clipboard to "\(appleScriptEscape(toLine))"
        tell application "System Events"
            tell process "Mail"
                set frontmost to true
                \(raiseOnly)
                keystroke "v" using command down
                delay \(stepDelay)
                keystroke tab
            end tell
        end tell
        delay \(stepDelay)
        """
    }

    // 1.7 (#219): verified sender popup. mailto always composes from the
    // DEFAULT account; a custom from_address is selected here by driving the
    // compose window's From popup. HARD REQUIREMENT (issue #219): selection
    // AND read-back use EXACT addr-spec equality, NOT substring containment
    // (#219 verify, Codex BLOCKING: `contains "user@x"` would match — and
    // wrongly VERIFY — a `notuser@x` account, sending from the wrong address).
    // `my senderMatches()` compares a menu label / popup value to the requested
    // account by EXACT match — bare `is _addr`, the `<addr>` angle-suffix, OR
    // the last space-delimited token (Mail's real `Name – addr` en-dash format,
    // #219 live-fix) — never by extraction (a quoted local-part could spoof
    // that; the caller normalizes `fromAddress` to a bare addr-spec and a
    // non-simple one is gated to legacy upstream by `isSimpleAddrSpec`). The
    // From popup is identified by its stable, locale-independent AXIdentifier
    // "popup_from" (#219 verify, Codex BLOCKING) — NOT a "value contains @"
    // scan, which a signature popup named like an email could satisfy and be
    // driven as the WRONG control. Any SENDERPOPUP error is pre-dispatch: the
    // on-error handler closes OUR window (saving no) and the Swift router falls
    // back to legacy `set sender` (correct sender beats clean body, #175).
    if let from = fromAddress, !from.isEmpty {
        let fromEsc = appleScriptEscape(from)
        s += """

        tell application "System Events"
            tell process "Mail"
                set frontmost to true
                \(raiseOnly)
                set _fromPopup to missing value
                -- #219 verify (Codex BLOCKING): identify the From popup by its
                -- stable, locale-independent AXIdentifier "popup_from" (live AX
                -- dump: priority=popup_priority, From=popup_from, signature=
                -- popup_signature), NEVER a "value contains @" scan — a signature
                -- popup whose value happens to hold an email (a user-named
                -- signature) could otherwise be picked as From and pass a
                -- self-consistent select + read-back on the WRONG control while
                -- the real From stays on the default account. #295: indexed +
                -- guarded fetch (a for-in item-fetch throws -2700 on an unstable
                -- AX tree). #219 live-fix: poll until the From popup's value is
                -- populated (empty for a beat after the window opens).
                repeat 12 times
                    set _fromPopup to missing value
                    set _pbTotal to 0
                    try
                        set _pbTotal to (count of pop up buttons of _w)
                    end try
                    repeat with _pbi from 1 to _pbTotal
                        try
                            set _pb to pop up button _pbi of _w
                            if (value of attribute "AXIdentifier" of _pb) is "popup_from" then
                                set _fromPopup to _pb
                                exit repeat
                            end if
                        end try
                    end repeat
                    if _fromPopup is not missing value then
                        set _fromValNow to ""
                        try
                            set _fromValNow to (value of _fromPopup as text)
                        end try
                        if _fromValNow contains "@" then exit repeat
                    end if
                    delay 0.3
                end repeat
                if _fromPopup is missing value then error "SENDERPOPUP: From popup (AXIdentifier popup_from) not found on the compose window"
                click _fromPopup
                delay \(stepDelay)
                -- #296: in-process NSAppleScript can evaluate the menu before it
                -- has opened/populated (settling-AX sibling of #295, menu layer —
                -- empirically: the identical matcher passes under osascript and
                -- gets ZERO items in-process). Poll for a populated menu; if
                -- still empty, re-click ONCE and poll again. Total failure falls
                -- to the existing sentinel (fail-closed unchanged). Enumeration
                -- is indexed + guarded, same as the #295 popup scan.
                set _miTotal to 0
                repeat 12 times
                    try
                        set _miTotal to (count of menu items of menu 1 of _fromPopup)
                    end try
                    if _miTotal > 0 then exit repeat
                    delay 0.3
                end repeat
                if _miTotal is 0 then
                    click _fromPopup
                    delay \(stepDelay)
                    repeat 12 times
                        try
                            set _miTotal to (count of menu items of menu 1 of _fromPopup)
                        end try
                        if _miTotal > 0 then exit repeat
                        delay 0.3
                    end repeat
                end if
                set _pickedItem to missing value
                ignoring case
                    repeat with _mii from 1 to _miTotal
                        try
                            set _mi to menu item _mii of menu 1 of _fromPopup
                            if my senderMatches(name of _mi as text, "\(fromEsc)") then
                                set _pickedItem to _mi
                                exit repeat
                            end if
                        end try
                    end repeat
                end ignoring
                if _pickedItem is missing value then
                    key code 53
                    error "SENDERPOPUP: no From account exactly matches \\"\(fromEsc)\\" (menu items seen: " & _miTotal & ")"
                end if
                click _pickedItem
                delay \(stepDelay)
                set _senderReadback to (value of _fromPopup as text)
                ignoring case
                    if not (my senderMatches(_senderReadback, "\(fromEsc)")) then error "SENDERPOPUP: read-back mismatch — popup shows \\"" & _senderReadback & "\\""
                end ignoring
            end tell
        end tell
        delay \(stepDelay)
        """
    }

    // 2. Attachments: re-raise OUR window, then one File ▸ Attach (⇧⌘A) cycle each,
    // path pasted into the Go-to-folder (⇧⌘G) field (clipboard set here, restored by
    // the caller in Swift). ASCII-only paths reach this flow: the sheet hangs
    // deterministically on CJK/fullwidth input even via paste (#220 live repro), so
    // non-ASCII paths are routed to the legacy native-attach path upstream — do NOT
    // remove that gate.
    if !attachments.isEmpty {
        for path in attachments {
            s += """

            tell application "System Events"
                tell process "Mail"
                    set frontmost to true
                    \(raiseOnly)
                    keystroke "a" using {command down, shift down}
                end tell
            end tell
            delay \(stepDelay)
            set the clipboard to "\(appleScriptEscape(path))"
            tell application "System Events"
                tell process "Mail"
                    keystroke "g" using {command down, shift down}
                    delay \(stepDelay)
                    keystroke "v" using command down
                    delay 0.4
                    key code 36
                    delay \(stepDelay)
                    key code 36
                end tell
            end tell
            delay \(stepDelay)
            """
        }
        // Drain: give the attachment(s) time to bind before dispatch (#60-style).
        s += "\n        delay \(attachDrain)\n"
    }

    // 3. Final re-raise + no-lingering-panel check + dispatch.
    // #242: for send:true the dispatch keystroke is wrapped in its own
    // POSTDISPATCH sentinel — once ⇧⌘D has been attempted, the send state is
    // UNKNOWN (the mail may already be on the wire), so the Swift layer must
    // not fall back to a legacy re-send (duplicate outbound). Pre-dispatch
    // errors (window lost, lingering sheet) stay unmarked → safe fallback.
    // ⌘S (draft save) keeps the plain fallback: a duplicated draft is visible
    // and harmless, unlike a duplicated send.
    let dispatchBlock: String
    if send {
        dispatchBlock = """
                try
                    \(dispatchKey)
                on error _dErr
                    error "POSTDISPATCH: " & _dErr
                end try
                set _dispatched to true
        """
    } else {
        dispatchBlock = "            \(dispatchKey)"
    }
    // #242: the on-error cleanup must NOT close the compose window when the
    // send state is unknown — that window is the user's only evidence. Only
    // send:true can produce sentinel-marked errors, so send:false keeps the
    // unconditional cleanup (AppleScript-equivalent to the pre-#242 script;
    // the cleanupBody extraction shifts leading whitespace, which AppleScript
    // ignores — verify #242, regression lens).
    let cleanupBody = """
            tell application "Mail"
                repeat with _cw in windows
                    try
                        if (id of _cw) is _ourId then close _cw saving no
                    end try
                end repeat
            end tell
    """
    // send:true handler: three branches, all rethrow — sentinel-marked errors
    // (keystroke) pass through untouched; unmarked errors with the flag set
    // (tail) get marked here; genuine pre-dispatch errors clean up + rethrow.
    let handlerBlock = send
        ? """
            if _mErr starts with "POSTDISPATCH:" then
                error _mErr
            else if _dispatched then
                error "POSTDISPATCH: " & _mErr
            else
        \(cleanupBody)
                error _mErr
            end if
        """
        : "\(cleanupBody)\n        error _mErr"
    // send:true keeps the settle delay INSIDE the outer try (flag-guarded);
    // send:false keeps it after end try, as before.
    let preHandlerTail = send ? "\n        delay \(stepDelay)" : ""
    let postTryTail = send ? "" : "\n    delay \(stepDelay)"
    s += """

        tell application "System Events"
            tell process "Mail"
                set frontmost to true
    \(verifyNoSheet)
    \(dispatchBlock)
            end tell
        end tell\(preHandlerTail)
    on error _mErr
    \(handlerBlock)
    end try\(postTryTail)
    return "\(dispatchLabel)"
    """
    return s
}

func buildComposeEmailScript(
    to: [String],
    subject: String,
    body: String,
    cc: [String]? = nil,
    bcc: [String]? = nil,
    attachments: [String]? = nil,
    format: BodyFormat = .plain,
    sanitizeLinks: Bool = false,
    fromAddress: String? = nil
) throws -> String {
    let composed = try renderBody(body, format: format, sanitizeLinks: sanitizeLinks)
    let plainFallback = composed.plainContent

    var script = """
    tell application "Mail"
        set newMessage to make new outgoing message with properties {subject:"\(appleScriptEscape(subject))", content:"\(appleScriptEscape(plainFallback))", visible:true}
        tell newMessage
    """

    // #131: sender account selection. Mail.app's outgoing-message `sender`
    // property is a STRING matching one of the user's configured email
    // addresses (RFC 5322 addr-spec, optionally with display name —
    // `"Name <email@example.com>"`). NOT an `account id` selector — Mail.app
    // routes outgoing messages by matching `sender` against configured
    // accounts. Omitted: Mail.app uses the default account (backward compat
    // — script remains byte-identical to pre-#131 output).
    if let from = fromAddress, !from.isEmpty {
        script += "\n        set sender to \"\(appleScriptEscape(from))\""
    }

    if let html = composed.htmlContent {
        script += "\n        set html content to \"\(appleScriptEscape(html))\""
    }

    script += "\n" + recipientFragment(to, kind: "to")
    if let cc = cc { script += "\n" + recipientFragment(cc, kind: "cc") }
    if let bcc = bcc { script += "\n" + recipientFragment(bcc, kind: "bcc") }
    if let attachments = attachments { script += "\n" + attachmentFragment(for: attachments) }

    script += "\n" + """
        end tell
        send newMessage
        return "Email sent successfully"
    end tell
    """

    return script
}

func buildCreateDraftScript(
    to: [String],
    subject: String,
    body: String,
    cc: [String]? = nil,
    bcc: [String]? = nil,
    attachments: [String]? = nil,
    format: BodyFormat = .plain,
    sanitizeLinks: Bool = false,
    fromAddress: String? = nil
) throws -> String {
    let composed = try renderBody(body, format: format, sanitizeLinks: sanitizeLinks)
    let plainFallback = composed.plainContent

    var script = """
    tell application "Mail"
        set newMessage to make new outgoing message with properties {subject:"\(appleScriptEscape(subject))", content:"\(appleScriptEscape(plainFallback))", visible:true}
        tell newMessage
    """

    // #131: sender account selection — see buildComposeEmailScript above.
    if let from = fromAddress, !from.isEmpty {
        script += "\n        set sender to \"\(appleScriptEscape(from))\""
    }

    if let html = composed.htmlContent {
        script += "\n        set html content to \"\(appleScriptEscape(html))\""
    }

    script += "\n" + recipientFragment(to, kind: "to")
    // cc / bcc emission order mirrors buildComposeEmailScript (#107).
    if let cc = cc { script += "\n" + recipientFragment(cc, kind: "cc") }
    if let bcc = bcc { script += "\n" + recipientFragment(bcc, kind: "bcc") }
    if let attachments = attachments { script += "\n" + attachmentFragment(for: attachments) }

    script += "\n" + """
        end tell
        save newMessage
        return "Draft created successfully"
    end tell
    """

    return script
}

func composeReplyHTML(userBody: String, userFormat: BodyFormat, originalHTML: String?, originalPlain: String, sanitizeLinks: Bool = false) throws -> String {
    let composed = try renderBody(userBody, format: userFormat, sanitizeLinks: sanitizeLinks)
    let userPart = composed.htmlContent ?? htmlEscape(userBody)

    let quoted: String
    if let html = originalHTML, !html.isEmpty {
        quoted = html
    } else {
        quoted = htmlEscape(originalPlain).replacingOccurrences(of: "\n", with: "<br>\n")
    }

    return "\(userPart)\n<hr>\n<blockquote>\n\(quoted)\n</blockquote>"
}

// Issue #43: AppleScript `& content` against a freshly-created outgoing message
// returns empty before the GUI compose pipeline materializes the quoted body.
// We pre-fetch the original plain text and Swift-side compose RFC 3676 quoted
// reply body so the result is deterministic regardless of window state.
//
// Round-1 hardening (#43 verify findings — Logic #1/2/3/5, Codex P1/P3):
// - Normalize CRLF/CR → LF before splitting (Mail.app IMAP/Exchange messages
//   sometimes return CRLF line endings).
// - Strip trailing newlines (Mail.app commonly appends a trailing newline,
//   which would emit a stray `> ` line at the end).
// - For empty quoted lines, emit `>` (no trailing space) per RFC 3676 §4.5;
//   only non-empty lines get the `> ` stuffing space.
// - After normalization, if there is no quotable content (e.g. originalPlain
//   was just whitespace/newlines), return userBody alone.
func composeReplyPlainText(userBody: String, originalPlain: String) -> String {
    let normalized = originalPlain
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    var trimmed = Substring(normalized)
    while let last = trimmed.last, last == "\n" {
        trimmed = trimmed.dropLast()
    }
    if trimmed.isEmpty {
        return userBody
    }
    let quoted = trimmed
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? ">" : "> \($0)" }
        .joined(separator: "\n")
    return "\(userBody)\n\n\(quoted)"
}

func buildReplyEmailScript(
    messageRef: String,
    userBody: String,
    userFormat: BodyFormat,
    replyAll: Bool,
    ccAdditional: [String]? = nil,
    attachments: [String]? = nil,
    saveAsDraft: Bool = false,
    originalHTML: String?,
    originalPlain: String,
    sanitizeLinks: Bool = false
) throws -> String {
    let replyType = replyAll ? "reply all" : "reply"
    let dispatchVerb = saveAsDraft ? "save" : "send"
    let returnMessage = saveAsDraft ? "Reply saved as draft" : "Reply sent successfully"
    // saveAsDraft=true: don't open Mail.app GUI window. The user wanted a quiet
    // draft for later review; popping a window invites them to edit it directly
    // and lose the saved snapshot. saveAsDraft=false: keep the existing
    // send-path behavior (window briefly opens during send, backward compat).
    let windowClause = saveAsDraft ? "without opening window" : "with opening window"

    let extraTellLines: String = {
        var lines: [String] = []
        if let cc = ccAdditional, !cc.isEmpty {
            lines.append(recipientFragment(cc, kind: "cc"))
        }
        if let atts = attachments, !atts.isEmpty {
            lines.append(attachmentFragment(for: atts))
        }
        return lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
    }()

    if userFormat == .plain {
        let composedPlain = composeReplyPlainText(userBody: userBody, originalPlain: originalPlain)
        return """
        tell application "Mail"
            set originalMsg to \(messageRef)
            set replyMsg to \(replyType) originalMsg \(windowClause)
            tell replyMsg
                set content to "\(appleScriptEscape(composedPlain))"\(extraTellLines)
            end tell
            \(dispatchVerb) replyMsg
            return "\(returnMessage)"
        end tell
        """
    }

    let finalHTML = try composeReplyHTML(
        userBody: userBody,
        userFormat: userFormat,
        originalHTML: originalHTML,
        originalPlain: originalPlain,
        sanitizeLinks: sanitizeLinks
    )

    return """
    tell application "Mail"
        set originalMsg to \(messageRef)
        set replyMsg to \(replyType) originalMsg \(windowClause)
        tell replyMsg
            set html content to "\(appleScriptEscape(finalHTML))"\(extraTellLines)
        end tell
        \(dispatchVerb) replyMsg
        return "\(returnMessage)"
    end tell
    """
}

func buildForwardEmailScript(
    messageRef: String,
    to: [String],
    userBody: String?,
    userFormat: BodyFormat,
    originalHTML: String?,
    originalPlain: String?,
    sanitizeLinks: Bool = false
) throws -> String {
    var script = """
    tell application "Mail"
        set originalMsg to \(messageRef)
        set fwdMsg to forward originalMsg with opening window
        tell fwdMsg
    """

    script += "\n" + recipientFragment(to, kind: "to")

    if let body = userBody {
        if userFormat == .plain {
            // Issue #44 (mirrors #43): use Swift-side composeReplyPlainText helper
            // instead of broken `& content` AppleScript. The pre-fix pattern read
            // outgoing message's `content` as empty before Mail.app's GUI populated
            // the quoted body — every plain forward since b8a4a89 silently dropped
            // the quoted original.
            let composedPlain = composeReplyPlainText(userBody: body, originalPlain: originalPlain ?? "")
            script += "\n" + """
                set content to "\(appleScriptEscape(composedPlain))"
            """
        } else {
            let finalHTML = try composeReplyHTML(
                userBody: body,
                userFormat: userFormat,
                originalHTML: originalHTML,
                originalPlain: originalPlain ?? "",
                sanitizeLinks: sanitizeLinks
            )
            script += "\n" + """
                set html content to "\(appleScriptEscape(finalHTML))"
            """
        }
    }

    script += "\n" + """
        end tell
        send fwdMsg
        return "Email forwarded successfully"
    end tell
    """

    return script
}

/// #134 — testable seam for reply_email's resolveMsgRef wiring.
///
/// Pre-#134 `MailController.replyEmail` computed `ref = resolveMsgRef(...)`
/// inline and threaded `ref` into the `(messageRef:)` builder. That overload
/// is byte-identical to what the actor produces, but the wiring step (the
/// literal `resolveMsgRef` call that #104 PR-C added for account_id
/// disambiguation) had **no automated regression lock** — reverting it to
/// the legacy `msgRef(...)` helper would leave `swift test` green and
/// silently bring back the #104 display_name-collision bug.
///
/// This overload internalizes the `resolveMsgRef` call so the wiring IS
/// unit-testable: `buildReplyEmailScript(id:..., accountId: uuid, ...)`
/// must emit `(account id "<UUID>")`, and the existing
/// `buildReplyEmailScript(messageRef:...)` overload stays intact for the
/// 25 legacy tests that pre-build the ref themselves.
///
/// `MailController.replyEmail` MUST use this overload (not the `messageRef:`
/// one with an inline `msgRef(...)` call) — that's the discipline this seam
/// codifies. Pre-fetch path still computes `ref` inline because it threads
/// through `buildFetchOriginalContentScript`; #134's scope is the main
/// reply script wiring (sibling issue can extend to the fetch path).
func buildReplyEmailScript(
    id: String,
    mailbox: String,
    accountId: String?,
    accountName: String,
    userBody: String,
    userFormat: BodyFormat,
    replyAll: Bool,
    ccAdditional: [String]? = nil,
    attachments: [String]? = nil,
    saveAsDraft: Bool = false,
    originalHTML: String?,
    originalPlain: String,
    sanitizeLinks: Bool = false
) throws -> String {
    let ref = resolveMsgRef(id: id, mailbox: mailbox,
                            accountId: accountId, accountName: accountName)
    return try buildReplyEmailScript(
        messageRef: ref,
        userBody: userBody,
        userFormat: userFormat,
        replyAll: replyAll,
        ccAdditional: ccAdditional,
        attachments: attachments,
        saveAsDraft: saveAsDraft,
        originalHTML: originalHTML,
        originalPlain: originalPlain,
        sanitizeLinks: sanitizeLinks
    )
}

/// #134 — testable seam for forward_email's resolveMsgRef wiring.
/// See `buildReplyEmailScript(id:mailbox:accountId:accountName:...)` for
/// the rationale; mirrors that pattern for forward.
func buildForwardEmailScript(
    id: String,
    mailbox: String,
    accountId: String?,
    accountName: String,
    to: [String],
    userBody: String?,
    userFormat: BodyFormat,
    originalHTML: String?,
    originalPlain: String?,
    sanitizeLinks: Bool = false
) throws -> String {
    let ref = resolveMsgRef(id: id, mailbox: mailbox,
                            accountId: accountId, accountName: accountName)
    return try buildForwardEmailScript(
        messageRef: ref,
        to: to,
        userBody: userBody,
        userFormat: userFormat,
        originalHTML: originalHTML,
        originalPlain: originalPlain,
        sanitizeLinks: sanitizeLinks
    )
}

// MARK: - #218 native-verb + paste reply/forward (wrapper-free new body)
//
// The legacy `buildReplyEmailScript` / `buildForwardEmailScript` above open the
// reply/forward window with the native verb but then OVERWRITE Mail's content
// with a self-composed body via `set content` / `set html content` — which Mail
// wraps in `Apple-Mail-URLShareWrapperClass` / `blockquote type="cite"` (the
// #218 bug, same mechanism as #175 compose).
//
// These builders keep Mail's NATIVE quote (the `reply`/`forward` verb builds it,
// correctly, in its own cite-blockquote + sets threading headers) and inject the
// NEW body ONLY via a System Events clipboard paste at the cursor — never `set
// content`/`set html content`. So the quoted original stays a proper quote and
// the user's new text is clean. Plain-only + Accessibility-gated (see
// `shouldUsePasteReplyForward`); the caller falls back to the legacy builders
// for markdown/html, no Accessibility, or any GUI failure.
//
// Window identity = id-delta (the `Re:`/`Fwd:` title prefix is LOCALIZED, so it
// is never matched). We capture window ids before the verb, diff to find the new
// window, read its ACTUAL title (`name of _w`, whatever locale) and bridge that
// real title into the System Events / AX context (where Mail's window id is not
// visible). On-error cleanup closes ONLY the windows we created (by id) — never a
// pre-existing user window (the #175-round-2 data-loss guard).

/// Shared core for the clean reply/forward paste path. `openVerb` is the native
/// Mail verb (`reply` / `reply all` / `forward`); `nativeLines` is the (already
/// `\n`-prefixed, helper-indented) cc/to/attachment fragment block to set on the
/// reply/forward message object, or `""` for none. Delays reuse the #175 mailto
/// env keys (same GUI-timing class).
private func buildReplyForwardPasteScript(
    messageRef: String,
    openVerb: String,
    msgVar: String,
    newBody: String,
    nativeLines: String,
    needsAttachDrain: Bool,
    send: Bool,
    successLabel: String,
    notOpenedError: String
) -> String {
    let windowDelay = resolvedDelay(envKey: "CHE_MAIL_MAILTO_WINDOW_DELAY", fallback: 1.8)
    let stepDelay = resolvedDelay(envKey: "CHE_MAIL_MAILTO_STEP_DELAY", fallback: 0.7)
    let attachDrain = resolvedDelay(envKey: "CHE_MAIL_MAILTO_ATTACH_DRAIN", fallback: 1.5)
    let dispatchKey = composeDispatchKeystroke(send: send)
    let bodyEsc = appleScriptEscape(newBody)

    // WINDOW IDENTITY — front-window-id guard (#218 verify; live-verified).
    //
    // The id-delta uniquely identifies OUR newly-opened window in the Mail object
    // model. But the keystrokes go through System Events / AX, and AX has no view
    // of Mail's window id. The mailto path (#175) bridges to AX by window TITLE —
    // which does NOT work here: Mail's reply/forward COMPOSE windows expose an
    // EMPTY `name` (the live test proved a reply window's title is ""), so a
    // title match would either refuse the (common) empty-title case → legacy-wrap,
    // or match the wrong same-titled window. Instead we use the guard the verify
    // reviewers (Logic + Devil's Advocate) recommended: in the MAIL context, gate
    // each keystroke phase on `id of front window` ∈ the id-delta set — i.e. OUR
    // window is the frontmost Mail window. `reply/forward with opening window`
    // opens the window frontmost; if the user stole focus during a delay, the id
    // won't match → error → on-error close (scoped to our ids) → MailController
    // catch → legacy injection fallback. Then `set frontmost to true` + keystroke
    // hits that frontmost window. RESIDUAL (inherent GUI automation, documented):
    // a sub-second TOCTOU between the Mail-side check and the AX keystroke remains
    // — same class as the #175 mailto residual; a detectable change degrades to
    // the legacy fallback.
    let frontGuard = """
        tell application "Mail"
            if (count of windows) is 0 then error "no Mail window to target (falling back)"
            if (id of front window) is not in _newIds then error "our reply/forward window is not frontmost (focus changed) — falling back"
        end tell
    """

    // #254: `_dispatched` flag (see the #242 block below) — initialized before
    // the outer try so the handler can always reference it; send-only.
    let rfFlagInit = send ? "set _dispatched to false\n    " : ""

    // 1. Capture ids, drive the native verb, compute the new-window id delta.
    var s = """
    tell application "Mail"
        set _beforeIds to (id of every window)
        set originalMsg to \(messageRef)
        set \(msgVar) to \(openVerb) originalMsg with opening window
    end tell
    delay \(windowDelay)
    tell application "Mail"
        set _afterIds to (id of every window)
        set _newIds to {}
        repeat with _k from 1 to (count of _afterIds)
            set _thisId to item _k of _afterIds
            if _beforeIds does not contain _thisId then set end of _newIds to _thisId
        end repeat
        if (count of _newIds) is 0 then error "\(notOpenedError)"
    end tell
    \(rfFlagInit)try
    \(frontGuard)
        tell application "System Events"
            tell process "Mail"
                set frontmost to true
                delay 0.25
                set the clipboard to "\(bodyEsc)"
                keystroke "v" using command down
                delay \(stepDelay)
            end tell
        end tell
    """

    // 2. Native cc/to/attachments on the message object — set AFTER the body
    // paste so the fresh body-top cursor is undisturbed (the paste lands above
    // Mail's quote; object mutations don't move the GUI insertion point).
    if !nativeLines.isEmpty {
        s += """

        tell application "Mail"
            tell \(msgVar)\(nativeLines)
            end tell
        end tell
        """
    }
    if needsAttachDrain {
        s += "\n        delay \(attachDrain)\n"
    }

    // 3. Re-confirm our window is still frontmost + no lingering panel + dispatch;
    // on-error closes ONLY the windows we created (by id), never a pre-existing
    // user window.
    //
    // Draft path closes its own window AFTER the dispatch succeeds: a saved-draft
    // ⌘S leaves the compose window OPEN (unlike a ⇧⌘D send, which closes it), so
    // without this every quiet draft accumulates a window — and an open compose
    // window also holds the draft, blocking later deletion. The close lives
    // OUTSIDE the `try` (best-effort, own inner `try`): a close failure must NOT
    // propagate into the legacy fallback, which would save a SECOND draft (the
    // double-dispatch hazard the "dispatch is the last statement in `try`"
    // ordering deliberately avoids). `saving yes` is a harmless re-save of the
    // already-saved draft, never a discard.
    // Both window closes ITERATE `every window` and test id membership, rather
    // than the `first window whose id is X` FILTER form — that filter is
    // unreliable on Mail compose windows (it silently fails the same way
    // `whose message id is` does), leaving the window open. Iteration + an
    // `(id of _cw) is in _newIds` membership check closes reliably (live-verified).
    let draftWindowClose = send ? "" : """


    tell application "Mail"
        repeat with _cw in (every window)
            try
                if (id of _cw) is in _newIds then close _cw saving yes
            end try
        end repeat
    end tell
    """
    // #254 (the #242 pattern, verbatim): for send:true the dispatch keystroke
    // gets its own POSTDISPATCH sentinel and the `_dispatched` flag marks any
    // error from the success-path tail — once ⇧⌘D has been attempted the send
    // state is UNKNOWN and the Swift layer must not fall back to a legacy
    // re-send (duplicate outbound reply/forward). The draft path (⌘S) keeps
    // the plain fallback and its post-try window close (a close failure must
    // never re-enter the legacy fallback — the double-dispatch hazard).
    let rfDispatchBlock: String
    if send {
        rfDispatchBlock = """
                    try
                        \(dispatchKey)
                    on error _dErr
                        error "POSTDISPATCH: " & _dErr
                    end try
                    set _dispatched to true
        """
    } else {
        rfDispatchBlock = "                \(dispatchKey)"
    }
    let rfCleanupBody = """
            tell application "Mail"
                repeat with _cw in (every window)
                    try
                        if (id of _cw) is in _newIds then close _cw saving no
                    end try
                end repeat
            end tell
    """
    let rfHandlerBlock = send
        ? """
            if _mErr starts with "POSTDISPATCH:" then
                error _mErr
            else if _dispatched then
                error "POSTDISPATCH: " & _mErr
            else
        \(rfCleanupBody)
                error _mErr
            end if
        """
        : "\(rfCleanupBody)\n        error _mErr"
    let rfPreHandlerTail = send ? "\n    delay \(stepDelay)" : ""
    let rfPostTryTail = send ? "" : "\n    delay \(stepDelay)"
    s += """

    \(frontGuard)
        tell application "System Events"
            tell process "Mail"
                set frontmost to true
                delay 0.25
                if (count of sheets of window 1) is not 0 then error "a sheet/panel is still open on the compose window"
    \(rfDispatchBlock)
            end tell
        end tell\(rfPreHandlerTail)
    on error _mErr
    \(rfHandlerBlock)
    end try\(rfPostTryTail)\(draftWindowClose)
    return "\(successLabel)"
    """
    return s
}

/// #218 — wrapper-free reply: native `reply`/`reply all` verb (Mail quotes the
/// original) + clipboard paste of the plain new body at the cursor. cc/attachments
/// are set natively on the reply message (unchanged from #34/#60). `saveAsDraft`
/// ⌘S vs send ⇧⌘D. The new body is NEVER `set content`/`set html content`.
func buildReplyEmailPasteScript(
    messageRef: String,
    newBody: String,
    replyAll: Bool,
    ccAdditional: [String]? = nil,
    attachments: [String]? = nil,
    saveAsDraft: Bool
) -> String {
    var fragments: [String] = []
    if let cc = ccAdditional, !cc.isEmpty {
        fragments.append(recipientFragment(cc, kind: "cc"))
    }
    let hasAttachments = (attachments?.isEmpty == false)
    if let atts = attachments, !atts.isEmpty {
        fragments.append(attachmentFragment(for: atts))
    }
    let nativeLines = fragments.isEmpty ? "" : "\n" + fragments.joined(separator: "\n")

    return buildReplyForwardPasteScript(
        messageRef: messageRef,
        openVerb: replyAll ? "reply all" : "reply",
        msgVar: "replyMsg",
        newBody: newBody,
        nativeLines: nativeLines,
        needsAttachDrain: hasAttachments,
        send: !saveAsDraft,
        successLabel: saveAsDraft ? "Reply saved as draft (paste path)"
                                  : "Reply sent successfully (paste path)",
        notOpenedError: "reply did not open a compose window"
    )
}

/// #218 — wrapper-free forward: native `forward` verb (Mail quotes the original)
/// + clipboard paste of the plain new note at the cursor. `to` recipients are set
/// natively on the forward message. Forward always sends (no draft mode in the
/// `forward_email` tool). The new note is NEVER `set content`/`set html content`.
func buildForwardEmailPasteScript(
    messageRef: String,
    to: [String],
    newBody: String
) -> String {
    let nativeLines = to.isEmpty ? "" : "\n" + recipientFragment(to, kind: "to")

    return buildReplyForwardPasteScript(
        messageRef: messageRef,
        openVerb: "forward",
        msgVar: "fwdMsg",
        newBody: newBody,
        nativeLines: nativeLines,
        needsAttachDrain: false,
        send: true,
        successLabel: "Email forwarded successfully (paste path)",
        notOpenedError: "forward did not open a compose window"
    )
}

func buildFetchOriginalContentScript(messageRef: String) -> String {
    return """
    tell application "Mail"
        set originalMsg to \(messageRef)
        try
            set originalHTML to html content of originalMsg
        on error
            set originalHTML to ""
        end try
        set originalPlain to content of originalMsg
        return originalHTML & "\u{001E}\u{001E}\u{001E}" & originalPlain
    end tell
    """
}

func parseFetchedOriginalContent(_ raw: String) -> (html: String?, plain: String) {
    let sep = "\u{001E}\u{001E}\u{001E}"
    let parts = raw.components(separatedBy: sep)
    if parts.count >= 2 {
        let html = parts[0]
        let plain = parts[1...].joined(separator: sep)
        return (html.isEmpty ? nil : html, plain)
    }
    return (nil, raw)
}
