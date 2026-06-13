import Foundation
import MailSQLite

/// One per-email entry in the `export_emails_markdown` manifest.
struct ExportManifestItem {
    let id: String              // input message id (SQLite rowId as string)
    let messageId: String?      // resolved RFC 5322 Message-ID (nil on fetch error)
    let writtenPath: String?    // absolute path of the written .md (nil on error)
    let attachments: [String]   // paths of saved attachments (relative to output_dir)
    let status: String          // "written" | "error"
    let error: String?

    var jsonObject: [String: Any] {
        var o: [String: Any] = ["id": id, "status": status, "attachments": attachments]
        if let m = messageId { o["message_id"] = m }
        if let p = writtenPath { o["written_path"] = p }
        if let e = error { o["error"] = e }
        return o
    }
}

/// Result of an `export_emails_markdown` run.
struct ExportManifest {
    let outputDir: String
    let items: [ExportManifestItem]

    var written: Int { items.filter { $0.status == "written" }.count }
    var errors: Int { items.filter { $0.status == "error" }.count }

    var jsonObject: [String: Any] {
        [
            "output_dir": outputDir,
            "written": written,
            "errors": errors,
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
        var name = template
            .replacingOccurrences(of: "{date}", with: localDate)
            .replacingOccurrences(of: "{subject}", with: slug(threadKey))
            .replacingOccurrences(of: "{sender}", with: sender)
            .replacingOccurrences(of: "{message_id}", with: slug(messageId))
        name = name.replacingOccurrences(of: "/", with: "-")
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
    ///   - saveAttachment: (id, name, destination) → writes the attachment.
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
        saveAttachment: (String, String, URL) throws -> Void,
        fileManager: FileManager = .default
    ) -> ExportManifest {
        try? fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var items: [ExportManifestItem] = []
        var seen: [String: Int] = [:]

        for id in ids {
            let content: EmailContent
            do {
                content = try fetch(id)
            } catch {
                items.append(ExportManifestItem(
                    id: id, messageId: nil, writtenPath: nil, attachments: [],
                    status: "error", error: "fetch: \(error.localizedDescription)"))
                continue
            }

            let threadKey = EmailMarkdownRenderer.stripReplyPrefixes(content.subject)
            let iso = EmailMarkdownRenderer.rfc822ToISO8601UTC(content.date)
            let localDate = String(iso.prefix(10))  // YYYY-MM-DD (UTC)
            let bareSender = EmailMarkdownRenderer.bareEmail(content.sender)

            // Resolve filename: per-id override > template > default(+collision).
            let filename: String
            if let override = filenameOverrides[id] {
                filename = override.hasSuffix(".md") ? override : override + ".md"
            } else if let template = filenameTemplate {
                filename = applyTemplate(template, localDate: localDate, threadKey: threadKey,
                                         sender: bareSender, messageId: content.messageId)
            } else {
                filename = defaultFilename(localDate: localDate, threadKey: threadKey, seen: &seen)
            }
            let stem = filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
            let destURL = outputDir.appendingPathComponent(filename)

            var md = EmailMarkdownRenderer.render(
                content, direction: direction, inReplyTo: "", extraFrontmatter: extraFrontmatter)

            var savedAttachments: [String] = []
            if includeAttachments {
                let names = (try? attachmentNamesFor(id)) ?? []
                for name in names {
                    let cls = attachmentClass(name)
                    let destDir: URL = cls == "data"
                        ? outputDir.appendingPathComponent("data", isDirectory: true)
                        : outputDir.appendingPathComponent("attachments", isDirectory: true)
                            .appendingPathComponent(stem, isDirectory: true)
                    try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
                    let attDest = destDir.appendingPathComponent(name)
                    do {
                        try saveAttachment(id, name, attDest)
                        // Path relative to outputDir for the manifest + markdown link.
                        let rel = cls == "data" ? "data/\(name)" : "attachments/\(stem)/\(name)"
                        savedAttachments.append(rel)
                    } catch {
                        // Attachment failure must not abort the email's markdown.
                        continue
                    }
                }
                if !savedAttachments.isEmpty {
                    md += "\n\nAttachments:\n"
                    md += savedAttachments.map { "- [\($0)](\($0))" }.joined(separator: "\n")
                    md += "\n"
                }
            }

            do {
                try md.data(using: .utf8)?.write(to: destURL, options: .atomic)
                items.append(ExportManifestItem(
                    id: id, messageId: content.messageId, writtenPath: destURL.path,
                    attachments: savedAttachments, status: "written", error: nil))
            } catch {
                items.append(ExportManifestItem(
                    id: id, messageId: content.messageId, writtenPath: nil,
                    attachments: savedAttachments, status: "error",
                    error: "write: \(error.localizedDescription)"))
            }
        }

        return ExportManifest(outputDir: outputDir.path, items: items)
    }
}
