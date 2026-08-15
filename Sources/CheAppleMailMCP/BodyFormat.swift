import Foundation

/// The `format` parameter of the composing tools.
///
/// #304 — `plain` is the only format a composing tool will act on. The other
/// two cases are deliberately RETAINED as parse targets so that
/// `format: "markdown"` / `format: "html"` can be refused with a message that
/// names what was removed and what to use instead. Deleting them would turn
/// those calls into a generic "unknown enum value" error, which tells a caller
/// nothing about why a format that used to work no longer does.
///
/// Both were removed because rich text is only expressible through the
/// AppleScript `html content` property, and assigning a body that way is what
/// makes Mail wrap the whole letter in `<blockquote type="cite">` (#175 / #304).
/// An alternative rich-text compose architecture is tracked in #308 / #309.
///
/// This type used to live in `MarkdownRendering.swift`, which #304 deleted along
/// with the markdown/HTML compose renderer. The export path
/// (`batch_export_emails_markdown`) is unaffected — it uses `EmailMarkdownRenderer`,
/// a separate module that never fed a composing script.
enum BodyFormat: String {
    case plain
    case markdown
    case html

    init?(rawValueOrNil: String?) {
        guard let raw = rawValueOrNil, !raw.isEmpty else {
            self = .plain
            return
        }
        guard let parsed = BodyFormat(rawValue: raw) else { return nil }
        self = parsed
    }
}
