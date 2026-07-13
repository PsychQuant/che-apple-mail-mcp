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
    let error: String?

    var jsonObject: [String: Any] {
        var o: [String: Any] = ["id": id, "status": status, "attachments": attachments]
        if let m = messageId { o["message_id"] = m }
        if let p = writtenPath { o["written_path"] = p }
        if !attachmentErrors.isEmpty { o["attachment_errors"] = attachmentErrors }
        if let e = error { o["error"] = e }
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
        let fd = open(path, O_WRONLY | O_CREAT, 0o644)
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

    var jsonObject: [String: Any] {
        [
            "output_dir": outputDir,
            "written": written,
            "errors": errors,
            "skipped": skipped,
            "items": items.map { $0.jsonObject },
        ]
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
    static func uniquify(_ filename: String, used: inout Set<String>) -> String {
        if !used.contains(filename) { used.insert(filename); return filename }
        let base = filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
        var n = 1
        var candidate = "\(base)-\(n).md"
        while used.contains(candidate) { n += 1; candidate = "\(base)-\(n).md" }
        used.insert(candidate)
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
    ///   - direction: `"received"` / `"sent"` (caller derives from mailbox).
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
        direction: String,
        includeAttachments: Bool,
        filenameTemplate: String?,
        filenameOverrides: [String: String],
        extraFrontmatter: [(String, String)],
        fetch: (String) throws -> EmailContent,
        attachmentNamesFor: (String) throws -> [String],
        attachmentData: (String, String) throws -> Data,
        skipMessageIds: Set<String> = [],
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
        // same outputDir (e.g. a mixed-direction corpus split into a received +
        // a sent batch, forced by the single `direction` param) re-derives
        // filenames from an empty set and silently overwrites same-(date,slug)
        // files written earlier. `uniquify()` (applied to every filename branch
        // — default/template/override — at the resolution site below) consults
        // this set, so seeding it is sufficient to make the suffix span calls.
        //
        // Case-insensitive `.md` match: template/override branches may emit
        // `.MD`/`.Md`, which must still seed the guard or a later default-cased
        // `.md` for the same (date,slug) could reuse the base name.
        do {
            let existing = try fileManager.contentsOfDirectory(
                at: outputDir, includingPropertiesForKeys: nil, options: [])
            for url in existing where url.pathExtension.lowercased() == "md" {
                usedFilenames.insert(url.lastPathComponent)
            }
        } catch {
            // Best-effort seed — the within-call guard still applies — but do NOT
            // stay silent. outputDir was just createDirectory'd, so a listing
            // failure here is a real error (permission / I/O), not the benign
            // not-yet-created case; leaving usedFilenames unseeded could let a
            // later same-(date,slug) file overwrite an earlier one, reintroducing
            // exactly the silent loss #232 removes. Surface it to stderr.
            FileHandle.standardError.write(Data(
                ("export_emails_markdown: could not list existing files in "
                 + outputDir.path + " to seed the cross-call collision guard ("
                 + error.localizedDescription
                 + "); same-(date,slug) filenames from a prior export to this "
                 + "directory may be overwritten.\n").utf8))
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

            let threadKey = EmailMarkdownRenderer.stripReplyPrefixes(content.subject)
            let iso = EmailMarkdownRenderer.rfc822ToISO8601UTC(content.date)
            // Date may be unparseable (rfc822ToISO8601UTC passes it through), so
            // keep only digits/dashes — never let a raw header reach a path.
            let rawDate = String(iso.prefix(10)).filter { $0.isNumber || $0 == "-" }
            let localDate = rawDate.isEmpty ? "unknown-date" : rawDate
            let bareSender = EmailMarkdownRenderer.bareEmail(content.sender)

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

            // Defence-in-depth: confirm the .md target canonicalizes back inside
            // output_dir before writing anything.
            guard isWithin(destURL, canonicalRoot: canonicalRoot) else {
                items.append(ExportManifestItem(
                    id: id, messageId: content.messageId, writtenPath: nil, attachments: [],
                    attachmentErrors: [], status: "error",
                    error: "filename escapes output_dir: \(filename)"))
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
                try RaceFreeFileWriter.writeFile(
                    rootDir: outputDir.path, relativeDirComponents: [],
                    filename: filename, data: Data(md.utf8))
                items.append(ExportManifestItem(
                    id: id, messageId: content.messageId, writtenPath: destURL.path,
                    attachments: savedAttachments, attachmentErrors: attachmentErrors,
                    status: "written", error: nil))
            } catch {
                // The .md failed — remove attachments already written so a failed
                // item leaves no orphan files behind.
                for url in savedAttachmentURLs { try? fileManager.removeItem(at: url) }
                items.append(ExportManifestItem(
                    id: id, messageId: content.messageId, writtenPath: nil,
                    attachments: [], attachmentErrors: attachmentErrors,
                    status: "error", error: "write: \(error.localizedDescription)"))
            }
        }

        return ExportManifest(outputDir: outputDir.path, items: items)
    }
}
