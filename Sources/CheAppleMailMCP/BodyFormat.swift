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
/// Both were removed because no path this project ships today can deliver rich
/// text without assigning the body through the AppleScript `html content`
/// property, and assigning it that way is what makes Mail wrap the whole letter
/// in `<blockquote type="cite">` (#175 / #304).
///
/// That is a statement about what exists, NOT a proof of impossibility (#310).
/// The clipboard paste path (#218) is a second wrapper-free route already in
/// production, and `NSPasteboard` can carry `public.rtf` / `public.html` — but
/// nobody has checked the MIME such a paste produces, so "rich text is
/// impossible without injection" is UNVERIFIED. #306 is the spike that settles
/// it; #308 / #309 are alternative architectures.
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
