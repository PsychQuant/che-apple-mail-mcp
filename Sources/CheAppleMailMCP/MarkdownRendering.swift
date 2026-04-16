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

func renderBody(_ body: String, format: BodyFormat) throws -> ComposedBody {
    switch format {
    case .plain:
        return ComposedBody(htmlContent: nil, plainContent: body)
    case .html:
        return ComposedBody(htmlContent: body, plainContent: body)
    case .markdown:
        let html = try markdownToHTML(body)
        return ComposedBody(htmlContent: html, plainContent: body)
    }
}

private func markdownToHTML(_ markdown: String) throws -> String {
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

    return attributedStringToHTML(attr)
}

private func attributedStringToHTML(_ attr: AttributedString) -> String {
    var paragraphs: [(text: String, kind: BlockKind)] = []
    var currentBuffer = ""
    var currentKind: BlockKind = .paragraph

    for run in attr.runs {
        let substring = attr[run.range]
        let text = String(substring.characters)

        let kind = blockKind(of: run.presentationIntent)

        // Block boundary: flush buffer when kind changes or run contains
        // a hard paragraph break (AttributedString splits paragraphs into
        // separate runs automatically, so a change in presentationIntent
        // identity signals a new block).
        if kind != currentKind && !currentBuffer.isEmpty {
            paragraphs.append((currentBuffer, currentKind))
            currentBuffer = ""
        }
        currentKind = kind

        currentBuffer += inlineHTML(text: text, run: run)
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

private func inlineHTML(text: String, run: AttributedString.Runs.Run) -> String {
    var fragment = htmlEscape(text)

    if let intent = run.inlinePresentationIntent {
        if intent.contains(.code) { fragment = "<code>\(fragment)</code>" }
        if intent.contains(.stronglyEmphasized) { fragment = "<strong>\(fragment)</strong>" }
        if intent.contains(.emphasized) { fragment = "<em>\(fragment)</em>" }
        if intent.contains(.strikethrough) { fragment = "<s>\(fragment)</s>" }
    }

    if let link = run.link {
        fragment = "<a href=\"\(link.absoluteString)\">\(fragment)</a>"
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
