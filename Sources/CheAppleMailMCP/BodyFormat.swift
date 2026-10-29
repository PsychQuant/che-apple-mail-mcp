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
/// property, which triggered the observed upstream wrapper regression FB11734014
/// (#175 / #304 / #310). Apple may fix it; public reports do not establish its
/// current private status or universal behavior across OS versions.
/// Evidence: https://developer.apple.com/forums/thread/738842
///
/// This is a product integration limit, NOT proof of impossibility (#310).
/// The #306 experiment reports four rich draft variants passing and the HTML
/// combination passing in Sent and received MIME. Those ASCII results do not
/// establish CJK, other OS versions, or sending with every flavor. Rich paste
/// is not integrated in the product; #308 / #309 are alternative architectures.
/// Evidence: https://github.com/PsychQuant/che-apple-mail-mcp/issues/306#issuecomment-5112852813
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
