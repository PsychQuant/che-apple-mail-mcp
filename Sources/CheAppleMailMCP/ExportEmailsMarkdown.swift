import Foundation
import MailSQLite

/// One per-email entry in the `export_emails_markdown` manifest.
struct ExportManifestItem {
    let id: String                   // input message id (SQLite rowId as string)
    let messageId: String?           // resolved RFC 5322 Message-ID (nil on fetch error)
    let writtenPath: String?         // absolute path of the written .md (nil on error)
    let attachments: [String]        // paths of saved attachments (relative to output_dir)
    let attachmentErrors: [String]   // per-attachment failures (never silently dropped)
    let status: String               // "written" | "error" | "skipped" (#177 dedup)
                                     //   | "header_only" (#283 skip_partial)
    let error: String?
    // #283 — negative-only partial-`.emlx` signal (#274 contract parity):
    // `false` = the content came from a partial file AND the renderer-selected
    // body (`textBody ?? htmlBody ?? ""`) is empty — the written .md is/would
    // be header-only; nil = no partial-file evidence of a missing body.
    // Never true. See `partialBodyMissingForExport`.
    var bodyDownloaded: Bool? = nil
    // #316 — negative-only fallback signal (mirrors `bodyDownloaded`):
    // `true` = this item's frontmatter `direction` came from the mailbox-label
    // fallback because sender identity could NOT be established; nil = it came
    // from sender identity. Never false.
    //
    // #351/#343 widened when it fires. It used to mean only "the own-addresses
    // set was empty", which missed the case that bit in practice: an EWS
    // account contributes no addresses while other accounts keep the set
    // non-empty, so mail the user sent from it was written `received` with no
    // signal at all. It now also fires when this email's own account
    // contributes no address, and when the `From` header does not parse.
    //
    // The contract consumers rely on is unchanged and is the reason this is
    // load-bearing: ABSENT means the value was derived from identity and can be
    // trusted. Emitting a wrong `direction` without this field is worse than
    // emitting an uncertain one with it.
    var directionInferred: Bool? = nil

    var jsonObject: [String: Any] {
        var o: [String: Any] = ["id": id, "status": status, "attachments": attachments]
        if let m = messageId { o["message_id"] = m }
        if let p = writtenPath { o["written_path"] = p }
        if !attachmentErrors.isEmpty { o["attachment_errors"] = attachmentErrors }
        if let e = error { o["error"] = e }
        if bodyDownloaded == false { o["body_downloaded"] = false }
        if directionInferred == true { o["direction_inferred"] = true }
        return o
    }
}

/// #236 — a concurrent `run()` against the same `output_dir` would race the
/// snapshot-seeded collision guard (both runs derive the same (date,slug)
/// filename before either writes) and the deterministic `.idd200.tmp` temp
/// names — silent last-rename-wins overwrites plus cross-run spurious errors.
enum ExportDirLockError: Error, CustomStringConvertible, LocalizedError {
    /// Another export run holds the lock on this output_dir.
    case busy(dir: String)
    /// The lockfile could not be opened / locked for an unexpected reason.
    case lockFailed(dir: String, errno: Int32)

    /// Server.swift renders tool errors via `error.localizedDescription` — a
    /// bare enum would render as an opaque "(ExportDirLockError error 0.)".
    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .busy(let dir):
            return "another export_emails_markdown run is currently writing to "
                + "'\(dir)' — concurrent exports to the same output_dir are "
                + "serialized to prevent silent filename-collision overwrites "
                + "(#236). Wait for the other run to finish and retry."
        case .lockFailed(let dir, let e):
            return "could not acquire the export lock in '\(dir)' "
                + "(errno \(e) — \(String(cString: strerror(e))))"
        }
    }
}

/// #236 — advisory per-output_dir lock covering an entire `run()`. Makes the
/// concurrent case equal the sequential case (which #232's cross-call seeding
/// already handles). `flock` is per open-file-description, so it serializes
/// both in-process overlapping tool calls AND separate server processes
/// (Claude Code plugin + Claude Desktop extension installs). Advisory only —
/// both writers we control are this binary; external writers are outside the
/// threat model (same assumption as #197/#200). Fail-fast (`LOCK_NB`), never
/// a blocking wait: an MCP tool call must not hang behind a long export.
struct ExportDirLock {
    static let lockFileName = ".export.lock"
    private let fd: Int32

    static func acquire(outputDir: URL) throws -> ExportDirLock {
        let path = outputDir.appendingPathComponent(lockFileName).path
        // #236 verify hardening: O_NOFOLLOW refuses a planted symlink at the
        // fixed lockfile path (parity with every RaceFreeFileWriter open —
        // #200 discipline); O_NONBLOCK turns a planted reader-less FIFO into
        // an immediate ENXIO instead of an open() hang BEFORE flock's LOCK_NB
        // fail-fast is even reached. O_NONBLOCK is a no-op for regular files.
        // O_CLOEXEC deliberately omitted: the export/tool path spawns no child
        // processes (AppleScript runs in-process via NSAppleScript) and the
        // codebase has no O_CLOEXEC convention — recorded in the #236 verify
        // report rather than cargo-culted.
        let fd = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o644)
        guard fd >= 0 else {
            throw ExportDirLockError.lockFailed(dir: outputDir.path, errno: errno)
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let e = errno
            close(fd)
            if e == EWOULDBLOCK {
                throw ExportDirLockError.busy(dir: outputDir.path)
            }
            throw ExportDirLockError.lockFailed(dir: outputDir.path, errno: e)
        }
        return ExportDirLock(fd: fd)
    }

    /// The lockfile itself persists between runs by design — unlinking it on
    /// release would reintroduce a race (a third run could lock a file the
    /// second run just unlinked). A stale dotfile in output_dir is harmless.
    func release() {
        close(fd)
    }
}

/// Result of an `export_emails_markdown` run.
struct ExportManifest {
    let outputDir: String
    let items: [ExportManifestItem]

    var written: Int { items.filter { $0.status == "written" }.count }
    var errors: Int { items.filter { $0.status == "error" }.count }
    /// #177: dedup-skipped (already-archived Message-ID) count.
    var skipped: Int { items.filter { $0.status == "skipped" }.count }
    /// #283: items whose content came from a partial `.emlx` with the body
    /// absent (`body_downloaded: false`) — written-but-header-only by default,
    /// or status "header_only" under `skip_partial`. O(1) SOP check.
    var bodyNotDownloaded: Int { items.filter { $0.bodyDownloaded == false }.count }

    var jsonObject: [String: Any] {
        [
            "output_dir": outputDir,
            "written": written,
            "errors": errors,
            "skipped": skipped,
            "body_not_downloaded": bodyNotDownloaded,
            "items": items.map { $0.jsonObject },
        ]
    }
}

/// The two identity inputs the export's `direction` decision depends on,
/// derived from `listAccounts()` output (#343/#351).
///
/// These live here rather than inline in `Server.swift` so they can be tested
/// against account shapes that are awkward to produce live — specifically an
/// EWS account, whose `AccountURL` is an opaque store id and which therefore
/// contributes NO address (#9). That shape is the whole of #351 and it was
/// invisible to the previous whole-set-emptiness test.
enum ExportIdentity {

    /// Every own address, each reduced by `EmailAddress.canonical` — the SAME
    /// function the sender goes through, which is the property that makes the
    /// comparison meaningful. Members that do not reduce to an address are
    /// dropped: keeping them would inflate the set with entries that can never
    /// match while suppressing the fail-open disclosure (#343-B).
    static func ownAddresses(from accounts: [[String: Any]]) -> Set<String> {
        Set(accounts
            .flatMap { ($0["email_addresses"] as? [String]) ?? [] }
            .compactMap { EmailAddress.canonical($0) })
    }

    /// UUIDs of accounts that contributed at least one usable address. An email
    /// whose account is absent here cannot be judged: a non-match means "this
    /// account's addresses are unknown", not "not yours".
    static func resolvedAccountUUIDs(from accounts: [[String: Any]]) -> Set<String> {
        Set(accounts.compactMap { account -> String? in
            let addrs = (account["email_addresses"] as? [String]) ?? []
            guard addrs.contains(where: { EmailAddress.canonical($0) != nil }),
                  let uuid = account["uuid"] as? String, !uuid.isEmpty else { return nil }
            return uuid
        })
    }
}

/// Server-side batch email → markdown export (issue #193, design D1/D5/D6).
///
/// The orchestration takes injected `fetch` / `attachmentNamesFor` /
/// `saveAttachment` closures so the batch logic (filename collision, manifest
/// assembly, partial-failure handling, attachment routing) is unit-testable
/// with in-memory fakes — no Mail store fixture required. `Server.swift` wires
/// the real `EnvelopeIndexReader` / `EmlxParser` closures.
enum ExportEmailsMarkdown {

    /// Data-class attachment extensions routed to `output_dir/data/`. Anything
    /// else is document-class, routed to `output_dir/attachments/<stem>/`.
    static let dataExtensions: Set<String> = [
        "csv", "tsv", "sav", "dta", "parquet", "feather", "xlsx", "sas7bdat", "rds",
    ]

    /// Classify an attachment filename as `"data"` or `"document"` by extension.
    static func attachmentClass(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        return dataExtensions.contains(ext) ? "data" : "document"
    }

    /// #283 — true when the fetched content came from a `.partial.emlx` AND
    /// the body the exported `.md` would carry is empty. RENDERER-aligned by
    /// construction: the emptiness test mirrors `EmailMarkdownRenderer`'s body
    /// selection (`textBody ?? htmlBody ?? ""`), so the flag means exactly
    /// "this export writes/would write a header-only file". Deliberately NOT
    /// the #274 `partialBodyNotDownloaded(format:)` helper with the fetch
    /// format "text" (#283 verify, Codex): a partial file can carry a full
    /// html-only body (Mail also uses `.partial.emlx` when attachments are
    /// stored externally; an html-only message has no text/plain part) — a
    /// text-only judgment would mis-flag it, and under `skip_partial` silently
    /// omit a complete email from the corpus forever (its re-export re-judges
    /// and re-skips). The `??`-precedence edge is intentional and pinned: a
    /// non-nil EMPTY text body wins the renderer selection even over present
    /// html content, so the rendered body IS empty → flagged.
    static func partialBodyMissingForExport(_ content: EmailContent) -> Bool {
        guard content.fromPartialEmlx else { return false }
        return (content.textBody ?? content.htmlBody ?? "").isEmpty
    }

    // MARK: - Write-safety (leaf-path containment)
    //
    // `AllowedRootsValidator` gates `output_dir`, but `URL.appendingPathComponent`
    // does NOT reject `..`, so a leaf name (sender-controlled attachment name,
    // caller-supplied filename override, or an unparseable Date passed through
    // into the default name) could escape the validated root. Every leaf the
    // tool builds is therefore (a) checked as a single safe path segment and/or
    // (b) re-verified to canonicalize back inside `output_dir` before any write.

    /// True if `name` is a single safe path segment: non-empty, no `/` or `\`,
    /// not `.`/`..`, and free of control characters / NUL. Sender-controlled
    /// attachment names that fail this are rejected (recorded, not written).
    static func isSafeSegment(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        if name.contains("/") || name.contains("\\") { return false }
        for scalar in name.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7f {
            return false
        }
        return true
    }

    /// Collapse a caller-supplied filename override (or template result) into a
    /// single safe path segment: path separators → `-`, control chars dropped,
    /// `.`/`..`/empty → `untitled`. Defence-in-depth paired with `isWithin`.
    static func sanitizeSegment(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "/", with: "-")
                   .replacingOccurrences(of: "\\", with: "-")
        s = String(String.UnicodeScalarView(
            s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }))
        s = s.trimmingCharacters(in: .whitespaces)
        return (s.isEmpty || s == "." || s == "..") ? "untitled" : s
    }

    /// True if `url` canonicalizes back to (or under) `canonicalRoot`. Uses the
    /// validator's symlink-resolving canonicalize, so it also defeats a
    /// pre-planted symlink at an intermediate directory (e.g. `output_dir/data`
    /// → elsewhere), not just lexical `..` traversal.
    static func isWithin(_ url: URL, canonicalRoot: String) -> Bool {
        let resolved = AllowedRootsValidator.canonicalize(url.path).path
        return resolved == canonicalRoot || resolved.hasPrefix(canonicalRoot + "/")
    }

    /// Ensure `filename` has not already been written this run; if it has,
    /// append `-1`, `-2`, … before `.md`. Applied uniformly across the default,
    /// template, and override branches so two emails can never silently
    /// overwrite each other (the per-`(date,slug)` counter only covers the
    /// default branch).
    /// Derive the default filename's `YYYY-MM-DD` part from the helper's ISO
    /// output. A passthrough (unparseable Date header) yields `unknown-date`
    /// rather than a fragment of the raw header ("13" from "Mon, 13 Jul …" —
    /// #244 verify): the prefix must be a complete calendar date or nothing.
    static func filenameDatePart(fromISO iso: String) -> String {
        let prefix = String(iso.prefix(10))
        let isCalendarDate = prefix.range(
            of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        return isCalendarDate ? prefix : "unknown-date"
    }

    /// The single key function for "are these two names the same file?" — used
    /// by `uniquify` AND by the cross-call on-disk seed, so the two can never
    /// drift apart (#342).
    ///
    /// `folding(.caseInsensitive)`, NOT `lowercased()`. APFS compares with full
    /// Unicode case-folding; `lowercased()` is a different operation and the
    /// gap is where #342 lived: `Straße.md`/`STRASSE.md` (ß folds to ss) and
    /// `ος.md`/`οσ.md` (Greek final sigma) are ONE directory entry on disk
    /// while `lowercased()` yields two distinct keys — so `uniquify` skipped
    /// the `-N` suffix and the second write replaced the first, with the
    /// manifest reporting both as `written`, `errors: 0`. Verified on a real
    /// APFS volume; `folding` agrees with the disk on every pair tested.
    ///
    /// Case ONLY — no `.diacriticInsensitive`. `cafe.md` and `café.md` are
    /// genuinely different files and must keep independent `-N` sequences.
    ///
    /// The residual asymmetry is deliberate: on a case-SENSITIVE volume this
    /// over-collides (a spurious `-1` suffix — cosmetic), whereas under-
    /// colliding loses data. Erring toward the fold is the safe side. The
    /// exclusive leaf rename below is what makes a residual miss loud instead
    /// of silent.
    static func collisionKey(_ filename: String) -> String {
        filename.folding(options: .caseInsensitive, locale: nil)
    }

    /// Membership is CASE-FOLDED (#313, corrected in #342): APFS — the macOS
    /// default — is case-insensitive but case-preserving, so `Re--X.md` and
    /// `RE--X.md` are one directory entry. Exact-string comparison let a
    /// case-variant slip through and silently overwrite the first file
    /// (manifest reported both as `written`, errors: 0 — P0 data loss). The
    /// `used` set therefore stores `collisionKey` keys only; the RETURNED name
    /// keeps the caller's original case, and the whole case-family shares one
    /// `-N` sequence.
    static func uniquify(_ filename: String, used: inout Set<String>) -> String {
        let key = collisionKey(filename)
        if !used.contains(key) { used.insert(key); return filename }
        let base = filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
        var n = 1
        var candidate = "\(base)-\(n).md"
        while used.contains(collisionKey(candidate)) { n += 1; candidate = "\(base)-\(n).md" }
        used.insert(collisionKey(candidate))
        return candidate
    }

    /// Sanitize a thread key into a filename slug: keep letters (incl. CJK) and
    /// digits, replace everything else with `-`, collapse repeated `-`, trim
    /// leading/trailing `-`, truncate to 50 grapheme clusters, `no-subject` when
    /// empty.
    static func slug(_ threadKey: String) -> String {
        var mapped = ""
        for ch in threadKey {
            if ch.isLetter || ch.isNumber { mapped.append(ch) } else { mapped.append("-") }
        }
        // Collapse runs of '-'.
        var collapsed = ""
        var lastDash = false
        for ch in mapped {
            if ch == "-" {
                if !lastDash { collapsed.append(ch) }
                lastDash = true
            } else {
                collapsed.append(ch)
                lastDash = false
            }
        }
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let truncated = String(trimmed.prefix(50)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return truncated.isEmpty ? "no-subject" : truncated
    }

    /// Compute the default filename for an email given the running collision
    /// counter. `localDate` is the `YYYY-MM-DD` prefix; the first file for a
    /// given `(localDate, slug)` has no suffix, the next `-1`, then `-2`, …
    /// Mutates `seen` (key → count already emitted).
    static func defaultFilename(
        localDate: String, threadKey: String, seen: inout [String: Int]
    ) -> String {
        let s = slug(threadKey)
        let key = "\(localDate)|\(s)"
        let count = seen[key, default: 0]
        seen[key] = count + 1
        let base = "\(localDate)_\(s)"
        return count == 0 ? "\(base).md" : "\(base)-\(count).md"
    }

    /// Apply a filename template with `{date}` / `{subject}` / `{sender}` /
    /// `{message_id}` placeholders. Result is sanitized to a single path
    /// component (path separators replaced) and `.md`-suffixed if absent.
    static func applyTemplate(
        _ template: String, localDate: String, threadKey: String,
        sender: String, messageId: String
    ) -> String {
        let expanded = template
            .replacingOccurrences(of: "{date}", with: localDate)
            .replacingOccurrences(of: "{subject}", with: slug(threadKey))
            .replacingOccurrences(of: "{sender}", with: sender)
            .replacingOccurrences(of: "{message_id}", with: slug(messageId))
        // `{sender}` expands raw, so route the whole result through the shared
        // single-segment sanitizer (collapses `/` and `\`, strips control
        // chars) rather than a one-off `/`→`-` pass.
        var name = sanitizeSegment(expanded)
        if !name.hasSuffix(".md") { name += ".md" }
        return name
    }

    /// Run the batch export.
    ///
    /// - Parameters:
    ///   - ids: message ids (SQLite rowId strings).
    ///   - outputDir: ALREADY-VALIDATED canonical output directory (the caller
    ///     runs `AllowedRootsValidator` first). Created if absent.
    ///   - ownAddresses: the user's own bare email addresses, each ALREADY put
    ///     through `EmailAddress.canonical` by the caller so both sides of the
    ///     identity comparison are produced by the same function (#343).
    ///     Per-email direction: sender ∈ set → `"sent"`, else `"received"`
    ///     (#316). Empty → every written item takes `fallbackDirection` and
    ///     discloses `direction_inferred: true`.
    ///   - fallbackDirection: `"received"` / `"sent"` — the mailbox-label
    ///     heuristic value, used only where identity cannot be established
    ///     (EWS/#9 accounts with no resolvable address, an unparseable `From`,
    ///     or index-less callers).
    ///   - identityResolvable: id → does THIS email's account contribute any
    ///     address to `ownAddresses`? A `false` means "cannot tell", which is a
    ///     different answer from "not yours" and must be disclosed rather than
    ///     resolved to `received` (#351). Defaults to `true` for callers that
    ///     have no per-account view; fail CLOSED (`false`) when the account
    ///     cannot be determined, so the doubt is disclosed rather than hidden.
    ///   - includeAttachments: also export each email's attachments.
    ///   - filenameTemplate / filenameOverrides: optional overrides (per design D4).
    ///   - extraFrontmatter: optional extra frontmatter fields.
    ///   - fetch: id → `EmailContent` (caller wires `EmlxParser.readEmail`, format "text").
    ///   - attachmentNamesFor: id → attachment filenames.
    ///   - attachmentData: (id, name) → the attachment's decoded bytes. The
    ///     export owns the filesystem write via the race-free `RaceFreeFileWriter`
    ///     (#200), so this only extracts bytes — it must not write.
    static func run(
        ids: [String],
        outputDir: URL,
        ownAddresses: Set<String>,
        fallbackDirection: String,
        includeAttachments: Bool,
        filenameTemplate: String?,
        filenameOverrides: [String: String],
        extraFrontmatter: [(String, String)],
        identityResolvable: (String) -> Bool = { _ in true },
        fetch: (String) throws -> EmailContent,
        attachmentNamesFor: (String) throws -> [String],
        attachmentData: (String, String) throws -> Data,
        skipMessageIds: Set<String> = [],
        skipPartial: Bool = false,
        fileManager: FileManager = .default
    ) throws -> ExportManifest {
        try? fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // #236: serialize whole-run access to this output_dir — the snapshot
        // seeding below and every write/manifest emit happen under the lock,
        // so an overlapping run fails fast instead of silently overwriting.
        let exportLock = try ExportDirLock.acquire(outputDir: outputDir)
        defer { exportLock.release() }
        // Canonical root every leaf path must stay within (the caller already
        // validated outputDir via AllowedRootsValidator).
        let canonicalRoot = AllowedRootsValidator.canonicalize(outputDir.path).path

        var items: [ExportManifestItem] = []
        var seen: [String: Int] = [:]          // default-branch (date,slug) counter
        var usedFilenames: Set<String> = []    // every .md filename emitted this run

        // #232: seed the collision guard with `.md` files already present in
        // outputDir from PRIOR run() calls, so the `-N` suffix continues ACROSS
        // calls — not just within one call. Without this, a second export to the
        // same outputDir (e.g. a corpus archived across multiple runs; before
        // #316 also the received/sent split forced by the then-single
        // `direction` param) re-derives
        // filenames from an empty set and silently overwrites same-(date,slug)
        // files written earlier. `uniquify()` (applied to every filename branch
        // — default/template/override — at the resolution site below) consults
        // this set, so seeding it is sufficient to make the suffix span calls.
        //
        // Seed keys go through `collisionKey` — the SAME function `uniquify`
        // uses, so the two can never drift (#313 inserted the ORIGINAL-case
        // name, which is how a `RE--` request sailed past an on-disk `Re--`
        // file; #342 then found `lowercased()` itself was the wrong fold for
        // `ß`/`ss` and Greek final sigma). The `.lowercased()` on pathExtension
        // is a separate concern — it keeps `.MD`/`.Md` files seeding the guard.
        do {
            let existing = try fileManager.contentsOfDirectory(
                at: outputDir, includingPropertiesForKeys: nil, options: [])
            for url in existing where url.pathExtension.lowercased() == "md" {
                usedFilenames.insert(collisionKey(url.lastPathComponent))
            }
        } catch {
            // Best-effort seed — the within-call guard still applies — but do NOT
            // stay silent. outputDir was just createDirectory'd, so a listing
            // failure here is a real error (permission / I/O), not the benign
            // not-yet-created case; leaving usedFilenames unseeded could let a
            // later same-(date,slug) file overwrite an earlier one, reintroducing
            // exactly the silent loss #232 removes. Surface it to stderr.
            Diagnostics.emit(
                ("export_emails_markdown: could not list existing files in "
                 + outputDir.path + " to seed the cross-call collision guard ("
                 + error.localizedDescription
                 + "); same-(date,slug) filenames from a prior export to this "
                 + "directory may be overwritten.\n"))
        }

        for id in ids {
            let content: EmailContent
            do {
                content = try fetch(id)
            } catch {
                items.append(ExportManifestItem(
                    id: id, messageId: nil, writtenPath: nil, attachments: [],
                    attachmentErrors: [], status: "error",
                    error: "fetch: \(error.localizedDescription)"))
                continue
            }

            // #177: dedup — skip an already-archived email (Message-ID in the
            // caller-supplied set) BEFORE any render/write. The content was fetched
            // binary-side (it never enters LLM context); a skip is recorded in the
            // manifest summary only.
            if !skipMessageIds.isEmpty, !content.messageId.isEmpty,
               skipMessageIds.contains(content.messageId) {
                items.append(ExportManifestItem(
                    id: id, messageId: content.messageId, writtenPath: nil, attachments: [],
                    attachmentErrors: [], status: "skipped", error: nil))
                continue
            }

            // #283 — closes the #274 gap on the bulk path: the fetch closure
            // (EmlxParser.readEmail, format "text") already carries
            // `fromPartialEmlx`, but the export used to drop it — header-only
            // archives were written with a clean "written" status. Judged by
            // the RENDERER-aligned predicate below, NOT the #274 helper with
            // the fetch format "text" (#283 verify, Codex): a partial file can
            // carry a full html-only body (Mail also uses .partial.emlx when
            // attachments are stored externally), which a text-only judgment
            // would mis-flag — and under skip_partial silently omit from the
            // corpus forever. Deliberately AFTER the #177 dedup skip: an
            // already-archived duplicate stays "skipped" and unannotated (it
            // will never be written, so a partial signal on it is noise).
            let partialBodyMissing = Self.partialBodyMissingForExport(content)
            let bodyDownloaded: Bool? = partialBodyMissing ? false : nil

            let threadKey = EmailMarkdownRenderer.stripReplyPrefixes(content.subject)
            let iso = EmailMarkdownRenderer.rfc822ToISO8601(content.date)
            let localDate = Self.filenameDatePart(fromISO: iso)
            let bareSender = EmailMarkdownRenderer.bareEmail(content.sender)

            // #316 — per-email direction from sender identity. Empty set =
            // fail-open (no resolvable own address): the caller's mailbox-label
            // fallback, disclosed per written item via the negative-only
            // `direction_inferred` manifest field.
            //
            // #351/#343 — the fail-open test used to be "is the WHOLE set
            // empty", which cannot see the case that actually bit: an EWS
            // account contributes NO addresses (its AccountURL is an opaque
            // store id, #9), while other accounts keep the set non-empty. Mail
            // the user sent from the EWS account then matched nothing, was
            // written `received`, and carried no disclosure — a confident wrong
            // answer. Measured on the reporting machine: 6 of 8 accounts
            // resolve, 2 EWS accounts resolve to nothing.
            //
            // So identity is now judged per email, and "I cannot tell" is a
            // distinct outcome from "not mine":
            //   sender ∈ own set                  → sent      (confident)
            //   sender unparseable, or this email's account contributes no
            //   addresses, or no address resolved at all
            //                                     → fallback  (disclosed)
            //   otherwise                         → received  (confident)
            // A positive match still wins first: mail sent from account A can
            // legitimately sit in account B's store.
            let canonicalSender = EmailAddress.canonical(content.sender)
            let direction: String
            let directionInferred: Bool?
            if let sender = canonicalSender, ownAddresses.contains(sender) {
                direction = "sent"
                directionInferred = nil
            } else if ownAddresses.isEmpty
                        || canonicalSender == nil
                        || !identityResolvable(id) {
                direction = fallbackDirection
                directionInferred = true
            } else {
                direction = "received"
                directionInferred = nil
            }

            // Resolve filename: per-id override > template > default(+collision).
            // Every branch yields a single sanitized segment, then `uniquify`
            // guarantees no two emails ever write to the same path.
            var filename: String
            if let override = filenameOverrides[id] {
                let seg = sanitizeSegment(override)
                filename = seg.hasSuffix(".md") ? seg : seg + ".md"
            } else if let template = filenameTemplate {
                filename = applyTemplate(template, localDate: localDate, threadKey: threadKey,
                                         sender: bareSender, messageId: content.messageId)
            } else {
                filename = defaultFilename(localDate: localDate, threadKey: threadKey, seen: &seen)
            }
            filename = uniquify(filename, used: &usedFilenames)
            let stem = filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
            let destURL = outputDir.appendingPathComponent(filename)

            // Opt-in `skip_partial`: keep the header-only email OUT of the
            // corpus (no stale .md to clean up, no collision-guard -N
            // duplicate on the re-export) — the SOP re-fetches flagged ids via
            // get_email (whose #274 fallback doubles as the download nudge)
            // and re-runs the export for just those ids. Default (false) stays
            // byte-compatible: still written, but annotated.
            //
            // Placed AFTER filename resolution + uniquify (#283 verify,
            // Codex): the skipped email still consumes its (date,slug) slot in
            // `seen`/`usedFilenames`, so name attribution is independent of
            // download state — its later re-export lands on the SAME name it
            // would have taken had it been complete in this run, and a
            // same-slug sibling in this run takes the -N suffix either way.
            if skipPartial, partialBodyMissing {
                items.append(ExportManifestItem(
                    id: id, messageId: content.messageId, writtenPath: nil, attachments: [],
                    attachmentErrors: [], status: "header_only", error: nil,
                    bodyDownloaded: false))
                continue
            }

            // Defence-in-depth: confirm the .md target canonicalizes back inside
            // output_dir before writing anything.
            guard isWithin(destURL, canonicalRoot: canonicalRoot) else {
                items.append(ExportManifestItem(
                    id: id, messageId: content.messageId, writtenPath: nil, attachments: [],
                    attachmentErrors: [], status: "error",
                    error: "filename escapes output_dir: \(filename)",
                    bodyDownloaded: bodyDownloaded))
                continue
            }

            // #198: thread the `In-Reply-To` header (was hard-coded `""`), so reply
            // threading via the `in_reply_to` frontmatter field works.
            // #199: signal the body type (text vs html-only) so a downstream
            // human/LLM reader knows when the verbatim body is raw HTML. It is
            // appended via `extraFrontmatter` — after the frozen core-6 fields and
            // any caller extras — so the published 6-field contract is unchanged.
            // The text/html choice mirrors the renderer's body selection
            // (`textBody ?? htmlBody ?? ""`): text when a plain body exists, html
            // when only an HTML body does, text for an empty body.
            let bodyType = content.textBody != nil ? "text"
                : (content.htmlBody != nil ? "html" : "text")
            var md = EmailMarkdownRenderer.render(
                content, direction: direction, inReplyTo: content.inReplyTo,
                extraFrontmatter: extraFrontmatter + [("body_type", bodyType)])

            var savedAttachments: [String] = []
            var savedAttachmentURLs: [URL] = []   // for orphan cleanup on .md write failure
            var attachmentErrors: [String] = []
            if includeAttachments {
                let names: [String]
                do {
                    names = try attachmentNamesFor(id)
                } catch {
                    names = []
                    attachmentErrors.append("list: \(error.localizedDescription)")
                }
                for name in names {
                    // The attachment name is sender-controlled MIME metadata.
                    // Reject anything that is not a single safe segment (path
                    // traversal / control chars) — recorded, never silently
                    // dropped.
                    guard isSafeSegment(name) else {
                        attachmentErrors.append("\(name): rejected (unsafe filename)")
                        continue
                    }
                    let cls = attachmentClass(name)
                    let destDir: URL = cls == "data"
                        ? outputDir.appendingPathComponent("data", isDirectory: true)
                        : outputDir.appendingPathComponent("attachments", isDirectory: true)
                            .appendingPathComponent(stem, isDirectory: true)
                    // Cheap canonical first-gate (a pre-existing symlink that
                    // resolves outside output_dir is caught here); the race-free
                    // `openat`-relative descent below is the actual enforcement
                    // against a symlink planted in the validate→write window.
                    guard isWithin(destDir, canonicalRoot: canonicalRoot) else {
                        attachmentErrors.append("\(name): destination escapes output_dir")
                        continue
                    }
                    let attDest = destDir.appendingPathComponent(name)
                    guard isWithin(attDest, canonicalRoot: canonicalRoot) else {
                        attachmentErrors.append("\(name): destination escapes output_dir")
                        continue
                    }
                    // #200: extract bytes, then write race-free (no-follow descent
                    // from the validated output_dir fd → a symlink swap can't redirect).
                    let relComponents = cls == "data" ? ["data"] : ["attachments", stem]
                    do {
                        let data = try attachmentData(id, name)
                        try RaceFreeFileWriter.writeFile(
                            rootDir: outputDir.path, relativeDirComponents: relComponents,
                            filename: name, data: data)
                        // Path relative to outputDir for the manifest + markdown link.
                        let rel = cls == "data" ? "data/\(name)" : "attachments/\(stem)/\(name)"
                        savedAttachments.append(rel)
                        savedAttachmentURLs.append(attDest)
                    } catch {
                        attachmentErrors.append("\(name): \(error.localizedDescription)")
                    }
                }
                if !savedAttachments.isEmpty {
                    md += "\n\nAttachments:\n"
                    md += savedAttachments.map { "- [\($0)](\($0))" }.joined(separator: "\n")
                    md += "\n"
                }
            }

            do {
                // #200: race-free write into the validated output_dir (the leaf
                // `.md` is created via a sibling temp + rename — a symlink at the
                // target is replaced, never followed).
                //
                // #342: `failIfExists` — the filename came from `uniquify`, whose
                // membership set is a PREDICTION of what the filesystem considers
                // the same name. #313 and #342 are two instances of that prediction
                // being wrong, each a silent overwrite. The exclusive rename asks
                // the volume itself, so a third instance is a loud manifest error
                // rather than lost mail. Attachments deliberately do NOT opt in —
                // re-saving the same attachment over itself is legitimate.
                try RaceFreeFileWriter.writeFile(
                    rootDir: outputDir.path, relativeDirComponents: [],
                    filename: filename, data: Data(md.utf8), failIfExists: true)
                items.append(ExportManifestItem(
                    id: id, messageId: content.messageId, writtenPath: destURL.path,
                    attachments: savedAttachments, attachmentErrors: attachmentErrors,
                    status: "written", error: nil,
                    bodyDownloaded: bodyDownloaded,
                    directionInferred: directionInferred))
            } catch {
                // The .md failed — remove attachments already written so a failed
                // item leaves no orphan files behind.
                for url in savedAttachmentURLs { try? fileManager.removeItem(at: url) }
                // #342: name the guard-miss explicitly. A bare
                // `localizedDescription` on this enum renders as an opaque
                // "error 8", which is exactly the kind of message that made the
                // original silent loss hard to notice.
                let reason: String
                if case RaceFreeWriteError.destinationExists(let n) = error {
                    reason = "collision guard miss: '\(n)' already exists on disk and was NOT "
                        + "overwritten. The filename guard folds case (#342), so this means the "
                        + "volume considers some existing file the same name by a rule the guard "
                        + "does not model. The existing file is intact; re-run after renaming or "
                        + "removing it, and please report the filename pair."
                } else {
                    reason = "write: \(error.localizedDescription)"
                }
                items.append(ExportManifestItem(
                    id: id, messageId: content.messageId, writtenPath: nil,
                    attachments: [], attachmentErrors: attachmentErrors,
                    status: "error", error: reason,
                    bodyDownloaded: bodyDownloaded))
            }
        }

        return ExportManifest(outputDir: outputDir.path, items: items)
    }
}
