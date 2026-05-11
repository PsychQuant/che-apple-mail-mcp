import Foundation

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

struct ComposedBody: Equatable {
    let htmlContent: String?
    let plainContent: String
}

enum MarkdownRenderingError: Error, Equatable {
    case markdownParseFailure(reason: String)
}

/// URL schemes considered "safe" — anchor will be emitted in
/// `<a href="...">` form. Schemes outside this set are stripped to text-
/// only when `sanitizeLinks: true` is passed to `renderBody`. List is
/// intentionally narrow (#19): `javascript:`, `data:`, `file:`, `vbscript:`
/// etc. are all rejected by default-off (preserves backwards compat) and
/// blocked by opt-in. Update `messageCompositionSafeURLSchemes` if a new
/// scheme proves universally safe across mail clients.
let messageCompositionSafeURLSchemes: Set<String> = ["http", "https", "mailto", "tel"]

/// Render a composing body to HTML / plain output.
///
/// - Parameters:
///   - body: caller-provided body text. Interpretation depends on `format`.
///   - format: `.plain` / `.markdown` / `.html`.
///   - sanitizeLinks: if `true`, link URLs whose scheme is not in
///     `messageCompositionSafeURLSchemes` are downgraded to plain text
///     (no anchor). Applies in `.markdown` mode (where `AttributedString`
///     parses link syntax and could surface `javascript:` or `data:` URLs
///     — see issue #19). `.plain` and `.html` modes are not affected:
///     plain doesn't render links, and html mode is by-design caller-
///     trusted (caller is responsible for sanitizing their own raw HTML).
///     Default `false` preserves pre-#19 behavior.
func renderBody(_ body: String, format: BodyFormat, sanitizeLinks: Bool = false) throws -> ComposedBody {
    switch format {
    case .plain:
        return ComposedBody(htmlContent: nil, plainContent: body)
    case .html:
        return ComposedBody(htmlContent: body, plainContent: body)
    case .markdown:
        let html = try markdownToHTML(body, sanitizeLinks: sanitizeLinks)
        return ComposedBody(htmlContent: html, plainContent: body)
    }
}

private func markdownToHTML(_ markdown: String, sanitizeLinks: Bool) throws -> String {
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .full,
        failurePolicy: .throwError
    )
    let attr: AttributedString
    do {
        attr = try AttributedString(markdown: markdown, options: options)
    } catch {
        throw MarkdownRenderingError.markdownParseFailure(reason: String(describing: error))
    }

    return attributedStringToHTML(attr, sanitizeLinks: sanitizeLinks)
}

private func attributedStringToHTML(_ attr: AttributedString, sanitizeLinks: Bool) -> String {
    var paragraphs: [(text: String, kind: BlockKind)] = []
    var currentBuffer = ""
    var currentKind: BlockKind = .paragraph
    var currentIntent: PresentationIntent? = nil
    var currentIntentInitialized = false

    for run in attr.runs {
        let substring = attr[run.range]
        let text = String(substring.characters)

        let intent = run.presentationIntent
        let kind = blockKind(of: intent)

        // Flush on any PresentationIntent change so adjacent same-kind blocks
        // (two paragraphs, two list items) get distinct output elements.
        // PresentationIntent is Hashable; each block instance carries a
        // unique identity per component, so equality here is a true
        // block-boundary check.
        let boundaryCrossed = currentIntentInitialized && intent != currentIntent
        if boundaryCrossed && !currentBuffer.isEmpty {
            paragraphs.append((currentBuffer, currentKind))
            currentBuffer = ""
        }
        currentKind = kind
        currentIntent = intent
        currentIntentInitialized = true

        currentBuffer += inlineHTML(text: text, run: run, sanitizeLinks: sanitizeLinks)
    }

    if !currentBuffer.isEmpty {
        paragraphs.append((currentBuffer, currentKind))
    }

    return assembleBlocks(paragraphs)
}

private enum BlockKind: Equatable {
    case paragraph
    case unorderedListItem
    case orderedListItem
    case codeBlock
    case blockquote
    case heading(Int)
}

private func blockKind(of intent: PresentationIntent?) -> BlockKind {
    guard let intent = intent else { return .paragraph }
    // Inspect the components (outermost first)
    for component in intent.components {
        switch component.kind {
        case .listItem:
            // Determine whether we're in an ordered or unordered list by
            // scanning the remaining components for the list type.
            for inner in intent.components where inner.kind != component.kind {
                switch inner.kind {
                case .orderedList:
                    return .orderedListItem
                case .unorderedList:
                    return .unorderedListItem
                default:
                    continue
                }
            }
            return .unorderedListItem
        case .codeBlock:
            return .codeBlock
        case .blockQuote:
            return .blockquote
        case .header(level: let level):
            return .heading(level)
        case .paragraph:
            continue
        default:
            continue
        }
    }
    return .paragraph
}

private func inlineHTML(text: String, run: AttributedString.Runs.Run, sanitizeLinks: Bool) -> String {
    var fragment = htmlEscape(text)

    if let intent = run.inlinePresentationIntent {
        if intent.contains(.code) { fragment = "<code>\(fragment)</code>" }
        if intent.contains(.stronglyEmphasized) { fragment = "<strong>\(fragment)</strong>" }
        if intent.contains(.emphasized) { fragment = "<em>\(fragment)</em>" }
        if intent.contains(.strikethrough) { fragment = "<s>\(fragment)</s>" }
    }

    if let link = run.link {
        // #19 — opt-in URL scheme allowlist. When sanitizeLinks=true and
        // the scheme is outside the allowlist (e.g. javascript:, data:,
        // file:, vbscript:), drop the anchor and emit text only —
        // AttributedString(markdown:) faithfully parses any URL the caller
        // typed, so without this guard a `[click](javascript:alert(1))`
        // would produce a clickable XSS vector in the rendered email.
        let scheme = link.scheme?.lowercased() ?? ""
        if sanitizeLinks && !messageCompositionSafeURLSchemes.contains(scheme) {
            // fragment stays as plain (escaped) text — no anchor wrapped
        } else {
            // Foundation's `URL.absoluteString` reliably percent-encodes characters
            // unsafe in URL syntax (including `"`), so today this interpolation is
            // safe. Wrap with `htmlEscape` anyway for defense-in-depth — pins the
            // contract that the href attribute value MUST be HTML-safe, independent
            // of Foundation's encoding behavior. See #87 (cluster A verify L#19b /
            // S2 follow-up). No-op for normal URLs; activates if a future
            // constructed URL ever produces a literal `"` / `<` / `&` / `>` in
            // `absoluteString` (theoretical).
            fragment = "<a href=\"\(htmlEscape(link.absoluteString))\">\(fragment)</a>"
        }
    }

    return fragment
}

private func assembleBlocks(_ blocks: [(text: String, kind: BlockKind)]) -> String {
    var html = ""
    var listOpen: BlockKind? = nil

    for (text, kind) in blocks {
        switch kind {
        case .unorderedListItem:
            if listOpen != .unorderedListItem {
                if listOpen != nil { html += closeList(listOpen!) }
                html += "<ul>\n"
                listOpen = .unorderedListItem
            }
            html += "<li>\(text)</li>\n"
        case .orderedListItem:
            if listOpen != .orderedListItem {
                if listOpen != nil { html += closeList(listOpen!) }
                html += "<ol>\n"
                listOpen = .orderedListItem
            }
            html += "<li>\(text)</li>\n"
        case .paragraph:
            if listOpen != nil { html += closeList(listOpen!); listOpen = nil }
            html += "<p>\(text)</p>\n"
        case .blockquote:
            if listOpen != nil { html += closeList(listOpen!); listOpen = nil }
            html += "<blockquote>\(text)</blockquote>\n"
        case .codeBlock:
            if listOpen != nil { html += closeList(listOpen!); listOpen = nil }
            html += "<pre><code>\(text)</code></pre>\n"
        case .heading(let level):
            if listOpen != nil { html += closeList(listOpen!); listOpen = nil }
            let clamped = max(1, min(6, level))
            html += "<h\(clamped)>\(text)</h\(clamped)>\n"
        }
    }

    if listOpen != nil { html += closeList(listOpen!) }
    return html
}

private func closeList(_ kind: BlockKind) -> String {
    switch kind {
    case .unorderedListItem: return "</ul>\n"
    case .orderedListItem: return "</ol>\n"
    default: return ""
    }
}

func htmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "&": out.append("&amp;")
        case "<": out.append("&lt;")
        case ">": out.append("&gt;")
        case "\"": out.append("&quot;")
        case "'": out.append("&#39;")
        default: out.append(ch)
        }
    }
    return out
}
