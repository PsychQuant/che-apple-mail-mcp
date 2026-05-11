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
    /// Unordered list item at the given nesting `depth` (1 = top-level,
    /// 2 = nested once, etc.). Pre-#16 used flat `.unorderedListItem`
    /// which collapsed nested items into the outer list. Depth comes
    /// from counting `listItem` components in the run's PresentationIntent.
    case unorderedListItem(depth: Int)
    /// Ordered list item at the given nesting `depth` (1 = top-level, etc.).
    /// Same depth semantics as `.unorderedListItem`.
    case orderedListItem(depth: Int)
    /// Code block. `languageHint` is the language tag from the fence
    /// (` ```swift ` → `"swift"`); nil for fences without a language tag
    /// (` ```\nfoo\n``` `). When non-nil, the emitted `<pre><code>` gets a
    /// `class="language-<hint>"` attribute (CommonMark recommended pattern,
    /// honored by Prism / Pygments / highlight.js / Mail clients with
    /// syntax-highlight plugins). See #22 Item D.
    case codeBlock(languageHint: String?)
    case blockquote
    case heading(Int)
    /// Table cell from a GFM markdown table. See #17.
    ///
    /// - `rowIndex`: row position. `nil` for cells in `tableHeaderRow`, integer
    ///   (>=1) for cells in regular `tableRow` (Foundation numbers data rows
    ///   from 1).
    /// - `columnIndex`: column position within the row (0-based).
    /// - `alignments`: per-column alignment from the GFM separator row
    ///   (`|---|:---|---:|:---:|` → [.left, .left, .right, .center]).
    ///   Used to emit `style="text-align: <align>"` on `<th>`/`<td>`.
    case tableCell(rowIndex: Int?, columnIndex: Int, alignments: [TableCellAlignment])
}

/// Per-column alignment from a GFM markdown table's separator row.
/// Mirrors `PresentationIntent.TableColumn.Alignment` without leaking
/// Foundation's nested type out of the file.
enum TableCellAlignment: Equatable {
    case left
    case center
    case right
}

private func blockKind(of intent: PresentationIntent?) -> BlockKind {
    guard let intent = intent else { return .paragraph }
    // Foundation emits `intent.components` INNER → OUTER (innermost block
    // kind first). For nested lists like:
    //     - A           [paragraph, listItem, unorderedList]
    //       1. B        [paragraph, listItem, orderedList, listItem, unorderedList]
    // the inner B's components start with the orderedList that DIRECTLY
    // contains it, then unwind out through the outer unorderedList.
    //
    // For list items we need:
    //   - depth = count of `listItem` components (one per nesting level)
    //   - kind = INNERMOST list type — the FIRST `*List` component seen
    //     (since iteration is inner→outer, the first wins).
    // For non-list blocks (paragraph/codeBlock/blockQuote/header) the first
    // such component seen wins.
    var listItemCount = 0
    var innermostListKind: PresentationIntent.Kind? = nil  // first list-kind in chain
    var firstNonListBlockKind: BlockKind? = nil
    // #17: table cell detection. Foundation emits cells as
    // `tableCell N > tableHeaderRow > table [...columns]` (header row) or
    // `tableCell N > tableRow M > table [...columns]` (data row).
    var tableColumnIndex: Int? = nil
    var tableRowIndex: Int? = nil       // nil for header row, >=1 for data rows
    var inTableHeaderRow: Bool = false
    var tableAlignments: [TableCellAlignment] = []
    var inTable: Bool = false

    for component in intent.components {
        switch component.kind {
        case .listItem:
            listItemCount += 1
        case .orderedList, .unorderedList:
            // First list-kind seen is the innermost — freeze it.
            if innermostListKind == nil {
                innermostListKind = component.kind
            }
        case .codeBlock(let languageHint):
            if firstNonListBlockKind == nil {
                firstNonListBlockKind = .codeBlock(languageHint: languageHint)
            }
        case .blockQuote:
            if firstNonListBlockKind == nil {
                firstNonListBlockKind = .blockquote
            }
        case .header(level: let level):
            if firstNonListBlockKind == nil {
                firstNonListBlockKind = .heading(level)
            }
        case .tableCell(let columnIndex):
            tableColumnIndex = columnIndex
        case .tableHeaderRow:
            inTableHeaderRow = true
        case .tableRow(let rowIndex):
            tableRowIndex = rowIndex
        case .table(let columns):
            inTable = true
            tableAlignments = columns.map { col in
                switch col.alignment {
                case .left:   return TableCellAlignment.left
                case .center: return .center
                case .right:  return .right
                @unknown default: return .left
                }
            }
        case .paragraph:
            continue
        default:
            continue
        }
    }

    // Table cells take highest precedence (data layout, not text block).
    if inTable, let col = tableColumnIndex {
        return .tableCell(
            rowIndex: inTableHeaderRow ? nil : tableRowIndex,
            columnIndex: col,
            alignments: tableAlignments
        )
    }
    // List-item blocks take precedence — a `listItem` in the chain means the
    // block lives inside a list, even if a `paragraph` or `header` component
    // also appears.
    if listItemCount > 0 {
        let isOrdered: Bool
        if case .orderedList? = innermostListKind {
            isOrdered = true
        } else {
            isOrdered = false
        }
        return isOrdered
            ? .orderedListItem(depth: listItemCount)
            : .unorderedListItem(depth: listItemCount)
    }
    return firstNonListBlockKind ?? .paragraph
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
    // #16: stack of currently-open list kinds (one entry per nesting depth).
    // listStack[0] = outermost open list (depth 1), listStack[N-1] = innermost
    // (depth N). Each entry tracks whether that level is ordered or unordered
    // so we can emit the right close tag.
    var listStack: [BlockKind] = []

    // #17: table state machine. Tracks the currently-open `<table>` (if any).
    // Foundation emits cells in row-major order; we open `<table><thead>` on
    // the first header cell, close `</tr></thead><tbody>` when we see the
    // first data row, transition `</tr><tr>` when row index changes, and
    // close `</tr></tbody></table>` when leaving table context.
    enum TableState {
        case none
        case inHeader(currentColumn: Int, alignments: [TableCellAlignment])
        case inBody(currentRow: Int, currentColumn: Int, alignments: [TableCellAlignment])
    }
    var tableState: TableState = .none

    // Helper: close lists from the top of the stack down to (but not
    // including) the target depth. Optionally also close the entry AT
    // target depth IF its kind differs from `requiredKind` (handles
    // same-depth UL→OL transitions). When stack.count < targetDepth
    // (we need to OPEN deeper levels), the kind check is skipped — the
    // outer lists stay open regardless of their kind.
    func closeListsTo(targetDepth: Int, requiredKind: BlockKind? = nil) {
        while listStack.count > targetDepth {
            html += closeList(listStack.removeLast())
        }
        // Same-depth kind transition check: only when we're EXACTLY at
        // targetDepth (not when we need to open deeper levels).
        if listStack.count == targetDepth,
           let required = requiredKind,
           let top = listStack.last,
           !sameListKind(top, required) {
            html += closeList(listStack.removeLast())
        }
    }

    // Helper: close the currently-open table (if any), emitting the proper
    // closing sequence for whichever sub-element the state machine is in.
    func closeTable() {
        switch tableState {
        case .none:
            return
        case .inHeader:
            html += "</tr></thead></table>\n"
        case .inBody:
            html += "</tr></tbody></table>\n"
        }
        tableState = .none
    }

    // Helper: alignment style attribute for a column. Default `.left` emits
    // no style attribute (browser default), which keeps simple tables clean.
    func styleAttr(_ align: TableCellAlignment) -> String {
        switch align {
        case .left:   return ""
        case .center: return " style=\"text-align: center\""
        case .right:  return " style=\"text-align: right\""
        }
    }

    for (text, kind) in blocks {
        switch kind {
        case .tableCell(let rowIndex, let columnIndex, let alignments):
            // Non-table blocks below (paragraph/heading/etc.) all call
            // closeTable() to leave table context — so if we get here we're
            // either continuing an open table or starting a new one.
            closeListsTo(targetDepth: 0)  // tables don't nest inside lists in this renderer

            let alignment = alignments.indices.contains(columnIndex) ? alignments[columnIndex] : .left

            switch tableState {
            case .none:
                // First cell — open table + thead/tr
                html += "<table>\n"
                if rowIndex == nil {
                    html += "<thead><tr>"
                    html += "<th\(styleAttr(alignment))>\(text)</th>"
                    tableState = .inHeader(currentColumn: columnIndex, alignments: alignments)
                } else {
                    // Skipping straight to data row (no header) — open tbody.
                    html += "<tbody><tr>"
                    html += "<td\(styleAttr(alignment))>\(text)</td>"
                    tableState = .inBody(currentRow: rowIndex!, currentColumn: columnIndex, alignments: alignments)
                }
            case .inHeader(let currentCol, let stateAlignments):
                if rowIndex == nil {
                    // Still in header row
                    if columnIndex > currentCol {
                        html += "<th\(styleAttr(alignment))>\(text)</th>"
                    } else {
                        // Shouldn't happen — but if columnIndex regresses, keep going
                        html += "<th\(styleAttr(alignment))>\(text)</th>"
                    }
                    tableState = .inHeader(currentColumn: columnIndex, alignments: stateAlignments)
                } else {
                    // Header → data row transition
                    html += "</tr></thead>\n<tbody><tr>"
                    html += "<td\(styleAttr(alignment))>\(text)</td>"
                    tableState = .inBody(currentRow: rowIndex!, currentColumn: columnIndex, alignments: stateAlignments)
                }
            case .inBody(let currentRow, _, let stateAlignments):
                if let newRow = rowIndex, newRow != currentRow {
                    html += "</tr>\n<tr>"
                    html += "<td\(styleAttr(alignment))>\(text)</td>"
                    tableState = .inBody(currentRow: newRow, currentColumn: columnIndex, alignments: stateAlignments)
                } else {
                    html += "<td\(styleAttr(alignment))>\(text)</td>"
                    if let r = rowIndex {
                        tableState = .inBody(currentRow: r, currentColumn: columnIndex, alignments: stateAlignments)
                    }
                }
            }

        case .unorderedListItem(let depth), .orderedListItem(let depth):
            closeTable()
            // Close any open lists deeper than this block's depth, and any
            // same-depth list whose kind doesn't match (UL→OL transition).
            closeListsTo(targetDepth: depth, requiredKind: kind)

            // Open new lists from current stack height up to this block's depth.
            while listStack.count < depth {
                let openKind = (listStack.count + 1 == depth) ? kind : kind  // same kind at each new level
                if case .orderedListItem = openKind {
                    html += "<ol>\n"
                } else {
                    html += "<ul>\n"
                }
                listStack.append(openKind)
            }

            html += "<li>\(text)</li>\n"

        case .paragraph:
            closeTable()
            closeListsTo(targetDepth: 0)
            html += "<p>\(text)</p>\n"
        case .blockquote:
            closeTable()
            closeListsTo(targetDepth: 0)
            html += "<blockquote>\(text)</blockquote>\n"
        case .codeBlock(let languageHint):
            closeTable()
            closeListsTo(targetDepth: 0)
            // #22 Item D: honor the language hint from the fence (e.g.
            // ` ```swift `) by emitting `class="language-swift"` on the
            // inner `<code>` element — CommonMark recommended pattern,
            // honored by Prism / highlight.js / mail clients with
            // syntax-highlight plugins. Plain fences (` ``` ` with no
            // language tag) keep the original `<pre><code>...` form.
            if let hint = languageHint, !hint.isEmpty {
                html += "<pre><code class=\"language-\(htmlEscape(hint))\">\(text)</code></pre>\n"
            } else {
                html += "<pre><code>\(text)</code></pre>\n"
            }
        case .heading(let level):
            closeTable()
            closeListsTo(targetDepth: 0)
            let clamped = max(1, min(6, level))
            html += "<h\(clamped)>\(text)</h\(clamped)>\n"
        }
    }

    // Close any remaining open table + lists at end of document.
    closeTable()
    closeListsTo(targetDepth: 0)
    return html
}

/// Compare two list-item BlockKinds by their list type (ordered vs unordered),
/// ignoring depth. Used by `closeListsTo` to detect UL→OL transitions at the
/// same depth.
private func sameListKind(_ a: BlockKind, _ b: BlockKind) -> Bool {
    switch (a, b) {
    case (.unorderedListItem, .unorderedListItem): return true
    case (.orderedListItem, .orderedListItem): return true
    default: return false
    }
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
