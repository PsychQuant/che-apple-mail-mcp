import Foundation
import MailSQLite

/// Renders a single `EmailContent` to the archive markdown format used by the
/// `export_emails_markdown` tool (issue #193, design decision D3).
///
/// Layout:
/// ```
/// ---
/// message_id: "<...>"
/// thread_key: "bare subject"
/// in_reply_to: "<...>"        (empty string when none)
/// date: 2026-06-13T08:01:14Z  (ISO 8601 UTC)
/// sender: bare@example.com
/// direction: received          (received | sent)
/// ---
///
/// Subject: ...
/// From: Name <addr>
/// To: a@x, b@y
/// Cc: c@z                       (line omitted when no cc)
/// Date: <original Date header>
///
/// <verbatim body>
/// ```
///
/// The six core frontmatter fields are a frozen published contract: callers
/// (e.g. the `archive-mail` workflow) depend on them. `extraFrontmatter`
/// appends further fields but never removes or reorders the core six. The
/// body is emitted verbatim — no summarization, paraphrase, or truncation.
enum EmailMarkdownRenderer {

    /// Build the markdown document for one email.
    ///
    /// - Parameters:
    ///   - content: parsed email (use `format: "text"` when reading so
    ///     `textBody` carries the verbatim body).
    ///   - direction: `"received"` or `"sent"` — derived by the caller from
    ///     the mailbox / account (not available on `EmailContent`).
    ///   - inReplyTo: the `In-Reply-To` Message-ID, or `""` when none —
    ///     resolved by the caller (not surfaced on `EmailContent`).
    ///   - extraFrontmatter: optional `(key, value)` pairs appended after the
    ///     core six fields.
    static func render(
        _ content: EmailContent,
        direction: String,
        inReplyTo: String,
        extraFrontmatter: [(String, String)] = []
    ) -> String {
        let threadKey = stripReplyPrefixes(content.subject)
        let isoDate = rfc822ToISO8601(content.date)
        let bareSender = bareEmail(content.sender)

        var out = "---\n"
        out += "message_id: \(yamlQuoted(content.messageId))\n"
        out += "thread_key: \(yamlQuoted(threadKey))\n"
        out += "in_reply_to: \(yamlQuoted(inReplyTo))\n"
        // `date` / `sender` are emitted unquoted (frozen contract format), so a
        // newline or control char in the value could inject a spurious YAML
        // line. `singleLine` flattens them; a normal ISO date / bare email is
        // unaffected (no control chars), so the published format is preserved.
        out += "date: \(singleLine(isoDate))\n"
        out += "sender: \(singleLine(bareSender))\n"
        out += "direction: \(direction)\n"
        for (key, value) in extraFrontmatter {
            out += "\(key): \(yamlQuoted(value))\n"
        }
        out += "---\n\n"

        out += "Subject: \(content.subject)\n"
        out += "From: \(content.sender)\n"
        out += "To: \(content.toRecipients.joined(separator: ", "))\n"
        if !content.ccRecipients.isEmpty {
            out += "Cc: \(content.ccRecipients.joined(separator: ", "))\n"
        }
        out += "Date: \(content.date)\n\n"

        out += content.textBody ?? content.htmlBody ?? ""
        return out
    }

    // MARK: - Helpers

    /// Reply/forward subject prefixes, stripped repeatedly to derive the
    /// thread key. Matches the set used by the archive-mail workflow.
    static let replyPrefixes = ["Re:", "RE:", "re:", "Fwd:", "FWD:", "FW:", "Fw:",
                                "转发:", "轉寄:", "回覆:", "回复:"]

    /// Strip leading reply/forward prefixes (repeatedly) and trim. Tolerates
    /// an optional space after the colon and between stacked prefixes.
    static func stripReplyPrefixes(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for prefix in replyPrefixes where s.lowercased().hasPrefix(prefix.lowercased()) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        return s
    }

    /// Extract the bare email address from a `From`/sender field such as
    /// `"Name" <addr@host>` → `addr@host`. Falls back to the trimmed input
    /// when there are no angle brackets.
    static func bareEmail(_ sender: String) -> String {
        if let lt = sender.lastIndex(of: "<"), let gt = sender.lastIndex(of: ">"), lt < gt {
            let start = sender.index(after: lt)
            return String(sender[start..<gt]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return sender.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Convert an RFC 822 / RFC 2822 email `Date` header to ISO 8601,
    /// preserving the header's numeric UTC offset (`+0800` → `…+08:00`) so the
    /// frontmatter agrees with the body `Date:` line (#244). A zero offset
    /// renders as the historical `Z`; a named or missing zone falls back to
    /// UTC; an unparseable date is returned unchanged (never crashes / never
    /// drops data).
    static func rfc822ToISO8601(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }

        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z",
        ]
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        for fmt in formats {
            parser.dateFormat = fmt
            if let date = parser.date(from: trimmed) {
                let out = DateFormatter()
                out.locale = Locale(identifier: "en_US_POSIX")
                if let offset = numericZoneOffsetSeconds(in: trimmed), offset != 0,
                   let zone = TimeZone(secondsFromGMT: offset) {
                    out.timeZone = zone
                    out.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
                } else {
                    out.timeZone = TimeZone(identifier: "UTC")
                    out.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
                }
                return out.string(from: date)
            }
        }
        return trimmed
    }

    /// Extract the numeric zone token (`+0800` / `-0530`) from an RFC 2822
    /// date string as seconds from GMT, or nil when the zone is named/absent.
    /// Anchored to the end of the string (where RFC 2822 puts the zone) so a
    /// `+`/`-` inside an obsolete comment can't be mistaken for the offset.
    private static func numericZoneOffsetSeconds(in dateString: String) -> Int? {
        guard let match = dateString.range(
            of: #"[+-]\d{4}\s*$"#, options: .regularExpression) else { return nil }
        let token = dateString[match].trimmingCharacters(in: .whitespaces)
        let sign = token.hasPrefix("-") ? -1 : 1
        let digits = token.dropFirst()
        guard digits.count == 4,
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.suffix(2)),
              hours <= 14, minutes < 60 else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }

    /// Wrap a value in double quotes for YAML frontmatter, replacing any
    /// embedded double-quote with a single-quote so the line stays parseable
    /// (matches the archive-mail convention; avoids escaping complexity).
    /// Control characters (CR/LF/NUL/etc.) are flattened to spaces first so a
    /// sender-controlled header cannot inject extra frontmatter lines.
    static func yamlQuoted(_ value: String) -> String {
        let flat = singleLine(value).replacingOccurrences(of: "\"", with: "'")
        return "\"\(flat)\""
    }

    /// Flatten any line break or control character to a single space and trim.
    /// Used for the unquoted `date` / `sender` frontmatter fields (and inside
    /// `yamlQuoted`) so no value can break out of its YAML line.
    static func singleLine(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Character in
            (scalar.value < 0x20 || scalar.value == 0x7f) ? " " : Character(scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }
}
