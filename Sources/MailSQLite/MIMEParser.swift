import Foundation

/// Parsed email content from MIME body.
public struct ParsedEmailContent: Sendable {
    public let textBody: String?
    public let htmlBody: String?
}

/// Parser for MIME message bodies.
/// Handles text/plain, text/html, multipart/*, and content-transfer-encoding.
public enum MIMEParser {

    /// Maximum depth of nested multipart recursion. Guards against
    /// maliciously-crafted messages that nest multipart/* indefinitely.
    /// 8 levels is well above anything seen in real mail corpora.
    static let maxMultipartDepth = 8

    /// Parse the body portion of an RFC 822 message given its headers.
    ///
    /// This is the **lossy** text-extraction API used by `get_email` /
    /// `list_emails` etc. It walks the multipart tree and keeps only the
    /// first `text/plain` and the first `text/html` it encounters; all
    /// other parts (attachments, inline images) are discarded.
    ///
    /// If you need to enumerate attachments or binary parts, use
    /// `parseAllParts` — which returns every part, non-lossy.
    ///
    /// - Parameters:
    ///   - bodyData: The raw body bytes (after header/body split).
    ///   - headers: Parsed headers from RFC822Parser.
    /// - Returns: Extracted text and/or HTML content.
    public static func parseBody(
        _ bodyData: Data,
        headers: [String: String]
    ) -> ParsedEmailContent {
        let contentType = headers["content-type"] ?? "text/plain"
        let cte = headers["content-transfer-encoding"] ?? "7bit"

        return parsePart(bodyData, contentType: contentType, encoding: cte)
    }

    /// Parse the body portion of an RFC 822 message into **every** MIME
    /// part it contains, including non-text attachments.
    ///
    /// This is the **non-lossy** enumeration API used by
    /// `AttachmentExtractor`. The existing `parseBody` is unchanged and
    /// remains the hot path for text/html extraction.
    ///
    /// The parts are returned in depth-first order matching the on-wire
    /// layout of the message. Callers that look up by filename should
    /// take the **first match** (first-match semantics — see
    /// `save-attachment-fast-path` design).
    ///
    /// Each part's `decodedData` is computed eagerly (base64 /
    /// quoted-printable / 7bit-8bit-binary passthrough). Any exotic
    /// transfer encoding is passed through unchanged (the raw bytes).
    ///
    /// - Parameters:
    ///   - bodyData: The raw body bytes (after header/body split).
    ///   - headers: Parsed headers from `RFC822Parser` (top-level message).
    /// - Returns: All MIME parts in depth-first order. Returns an empty
    ///   array for malformed multipart (missing boundary, depth limit
    ///   exceeded, etc.) so callers can fall back gracefully.
    public static func parseAllParts(
        _ bodyData: Data,
        headers: [String: String]
    ) -> [MIMEPart] {
        let contentType = headers["content-type"] ?? "text/plain"
        let cte = headers["content-transfer-encoding"] ?? "7bit"

        var parts: [MIMEPart] = []
        collectParts(
            body: bodyData,
            partHeaders: headers,
            contentType: contentType,
            encoding: cte,
            depth: 0,
            out: &parts
        )
        return parts
    }

    /// Enumerate attachment filenames in a body without decoding any
    /// transfer-encoded data. Returns the union of `Content-Disposition:
    /// filename` (RFC 2231/5987 decoded) and the legacy `Content-Type: name`
    /// parameter for every leaf part.
    ///
    /// Faster + lower-memory alternative to `parseAllParts` when the caller
    /// only needs the set of names (e.g. for cross-validating SQLite cached
    /// attachment metadata against the `.emlx` body — see issue #24).
    /// Critically, this walker **does not** call `decodeTransferEncoding`,
    /// so a 50-MB base64-encoded attachment is not allocated into memory
    /// just to read its `filename` parameter.
    ///
    /// Honors the same `maxMultipartDepth=8` guard as `parseAllParts`.
    ///
    /// **Malformed multipart handling** (#26 fix, was #24 verify-finding):
    /// When the top-level Content-Type declares a `multipart/*` body but
    /// the parser cannot extract any meaningful structure (missing
    /// boundary, header/body split fails on every child, depth limit
    /// exceeded), this function **throws `MailSQLiteError.emlxParseFailed`**
    /// instead of silently returning an empty set. Rationale:
    ///
    /// - Pre-#26 behavior returned `Set()` for malformed input, which the
    ///   `list_attachments` cross-validation filter then used to drop ALL
    ///   SQLite rows. Net effect: users saw 0 attachments on legitimately-
    ///   broken `.emlx` files with cached SQLite metadata.
    /// - Throwing surfaces the parse failure to the handler, which already
    ///   has a `do/catch` wrapper that falls back to unvalidated SQLite
    ///   metadata (`Server.swift:list_attachments` and
    ///   `list_attachments_batch` per-message paths). User now sees the
    ///   SQLite-cached names instead of the empty post-filter result.
    /// - For NON-multipart inputs (single-part `text/plain`, etc.), or
    ///   multipart inputs that yield ≥1 leaf, behavior is unchanged
    ///   (returns the collected names; may legitimately be empty if no
    ///   leaf has a filename — that's an attachment-less message, not a
    ///   parse failure).
    ///
    /// - Parameters:
    ///   - bodyData: The raw body bytes (after header/body split).
    ///   - headers: Parsed headers from `RFC822Parser` (top-level message).
    /// - Returns: Set of attachment names (deduplicated).
    /// - Throws: `MailSQLiteError.emlxParseFailed` if the top-level
    ///           declared multipart cannot be split at all.
    public static func enumerateAttachmentNames(
        _ bodyData: Data,
        headers: [String: String]
    ) throws -> Set<String> {
        // Derived from the name → inline-presence map: the key set is exactly
        // the legacy return value. Keeps a single no-decode tree walk (#105).
        return Set(try enumerateAttachmentInlinePresence(bodyData, headers: headers).keys)
    }

    /// Like `enumerateAttachmentNames`, but reports for each attachment name
    /// whether the part carries a non-empty **inline** body in the `.emlx`
    /// envelope (`true`) or has had it stripped (`false`).
    ///
    /// A `false` here means the binary lives only in Apple Mail's external
    /// `Attachments/<rowId>/` cache (`.partial.emlx` messages) — or nowhere at
    /// all. It does **not** by itself mean the attachment is unsavable; the
    /// caller still has to check the external cache (see
    /// `AttachmentExtractor.attachmentSavability`). Used by `list_attachments`'
    /// `savable` field (#105).
    ///
    /// Same no-decode tree walk as `enumerateAttachmentNames` — inline
    /// presence is "the raw leaf body has any non-whitespace byte" (a
    /// `.partial.emlx` strips an attachment body down to the lone CRLF before
    /// the next boundary, and base64/QP of whitespace-only input decodes to
    /// empty), so a 50-MB base64 attachment is still never decoded just to
    /// answer this question (the #24 perf property is preserved).
    ///
    /// - Throws: `MailSQLiteError.emlxParseFailed` on the same malformed
    ///   top-level-multipart condition as `enumerateAttachmentNames` (#26).
    public static func enumerateAttachmentInlinePresence(
        _ bodyData: Data,
        headers: [String: String]
    ) throws -> [String: Bool] {
        let contentType = headers["content-type"] ?? "text/plain"

        var presence = [String: Bool]()
        var topLevelMultipartSplitFailed = false
        collectAttachmentNames(
            body: bodyData,
            partHeaders: headers,
            contentType: contentType,
            depth: 0,
            out: &presence,
            topLevelMultipartSplitFailed: &topLevelMultipartSplitFailed
        )
        // Distinguish "legitimately empty multipart" (some splits succeeded,
        // no leaves with filenames) from "all splits failed" (the parser
        // never made it past the top-level boundary). The latter is what
        // #26 calls "malformed multipart" — surface as throw so the handler
        // can fall through to SQLite-cached metadata.
        if topLevelMultipartSplitFailed {
            throw MailSQLiteError.emlxParseFailed(
                "MIMEParser: top-level multipart declared in Content-Type but "
                + "no parseable structure recovered (missing/wrong boundary, "
                + "all children unparseable, or depth limit exceeded). "
                + "Caller should fall back to unvalidated SQLite metadata."
            )
        }
        return presence
    }

    /// Recursive walker mirroring `collectParts`, but skipping the
    /// `decodeTransferEncoding` call on leaf parts. See
    /// `enumerateAttachmentNames` docstring for rationale.
    ///
    /// `topLevelMultipartSplitFailed` is an out-param the top-level call
    /// inspects after recursion. It's set to `true` only when the TOP-level
    /// body (`depth == 0`) is declared `multipart/*` but no child split
    /// succeeded — distinguishes #26's malformed case from legitimately
    /// empty multiparts where some children parsed but had no filenames.
    /// `out` maps each attachment name to whether its part carries an inline
    /// body — defined as "the raw leaf body has any non-whitespace byte". When
    /// the same name appears on multiple parts, the **first occurrence in
    /// document order wins** — this mirrors `AttachmentExtractor.saveAttachment`,
    /// which saves `parts.first(where: matchesAttachmentName)`. OR-combining
    /// instead would overstate savability: a `savable: true` driven by a later
    /// duplicate while `save_attachment` resolves the first (stripped) part and
    /// fails (#105, Codex verify finding).
    private static func collectAttachmentNames(
        body: Data,
        partHeaders: [String: String],
        contentType: String,
        depth: Int,
        out: inout [String: Bool],
        topLevelMultipartSplitFailed: inout Bool
    ) {
        guard depth < maxMultipartDepth else {
            // Depth exceeded at non-top level — just stop recursion.
            // Top-level depth-exceeded is impossible (depth starts at 0).
            return
        }

        let (mimeType, params) = parseContentType(contentType)

        if mimeType.hasPrefix("multipart/") {
            guard let boundary = params["boundary"], !boundary.isEmpty else {
                // Declared multipart but no boundary — at top level this is
                // the #26 malformed signal.
                if depth == 0 { topLevelMultipartSplitFailed = true }
                return
            }
            let children = splitMultipart(body, boundary: boundary)
            var anyChildParsed = false
            children.forEach { childData in
                guard let split = RFC822Parser.headerBodySplitOffset(in: childData) else {
                    return
                }
                anyChildParsed = true
                let childHeaders = RFC822Parser.parseHeaders(from: childData)
                let childBody = Data(childData[split...])
                let childCT = childHeaders["content-type"] ?? "text/plain"
                collectAttachmentNames(
                    body: childBody,
                    partHeaders: childHeaders,
                    contentType: childCT,
                    depth: depth + 1,
                    out: &out,
                    topLevelMultipartSplitFailed: &topLevelMultipartSplitFailed
                )
            }
            // Top-level multipart declared but NO child parsed (split
            // returned 0 chunks OR every chunk missing header/body split)
            // — this is the #26 malformed signal.
            if depth == 0 && !anyChildParsed {
                topLevelMultipartSplitFailed = true
            }
            return
        }

        // Leaf part — extract names without decoding body. Inline presence is
        // "the raw (still transfer-encoded) leaf body has any non-whitespace
        // byte": a `.partial.emlx` strips the attachment body down to just the
        // CRLF before the next boundary, and base64/QP of whitespace-only input
        // decodes to empty — so a whitespace-only body means "no inline binary"
        // without paying for a transfer-decode (#105). `.contains` early-exits
        // on the first content byte, so a real attachment costs O(1) here.
        let inlinePresent = body.contains { byte in
            byte != 0x20 && byte != 0x09 && byte != 0x0D && byte != 0x0A
        }
        let (_, dispositionParams) = parseContentDisposition(
            partHeaders["content-disposition"]
        )
        // First occurrence in document order wins — see the docstring: this
        // mirrors saveAttachment's `parts.first(where:)` selection (#105).
        if let filename = resolveFilename(
            dispositionParams: dispositionParams,
            contentTypeParams: params
        ), out[filename] == nil {
            out[filename] = inlinePresent
        }
        // Legacy `Content-Type: name=` add point. Apply the same per-parameter
        // RFC 2047 decode as `resolveFilename` path 4 — symmetric — so the
        // emitted name set never contains a spurious raw `=?…?=` entry once
        // raw-header-level decoding is gone for Content-* (#115 verify, Codex).
        if let name = params["name"] {
            let decoded = decodeRFC2047IfApplicable(name)
            if out[decoded] == nil {
                out[decoded] = inlinePresent
            }
        }
    }

    // MARK: - parseAllParts internals

    /// Recursive walker. Either adds a leaf `MIMEPart` to `out`, or
    /// descends into a multipart boundary to collect child parts.
    private static func collectParts(
        body: Data,
        partHeaders: [String: String],
        contentType: String,
        encoding: String,
        depth: Int,
        out: inout [MIMEPart]
    ) {
        // Depth guard — prevents malicious multipart bomb.
        guard depth < maxMultipartDepth else { return }

        let (mimeType, params) = parseContentType(contentType)

        if mimeType.hasPrefix("multipart/") {
            guard let boundary = params["boundary"], !boundary.isEmpty else {
                // Malformed multipart header → no children, nothing to do.
                return
            }
            splitMultipart(body, boundary: boundary).forEach { childData in
                guard let split = RFC822Parser.headerBodySplitOffset(in: childData) else {
                    return
                }
                let childHeaders = RFC822Parser.parseHeaders(from: childData)
                let childBody = Data(childData[split...])
                let childCT = childHeaders["content-type"] ?? "text/plain"
                let childCTE = childHeaders["content-transfer-encoding"] ?? "7bit"
                collectParts(
                    body: childBody,
                    partHeaders: childHeaders,
                    contentType: childCT,
                    encoding: childCTE,
                    depth: depth + 1,
                    out: &out
                )
            }
            return
        }

        // Leaf part — decode and emit.
        let decoded = decodeTransferEncoding(body, encoding: encoding)

        let (disposition, dispositionParams) = parseContentDisposition(
            partHeaders["content-disposition"]
        )

        let filename = resolveFilename(
            dispositionParams: dispositionParams,
            contentTypeParams: params
        )

        out.append(MIMEPart(
            headers: partHeaders,
            contentType: mimeType,
            contentTypeParams: params,
            contentDisposition: disposition,
            filename: filename,
            rawBytes: body,
            decodedData: decoded
        ))
    }

    /// Split a multipart body into child part bytes (each child includes
    /// its own headers + body + trailing CRLF).
    ///
    /// Apple Mail sometimes stores `.emlx` files as UTF-8, sometimes as
    /// Latin-1 (any 8-bit binary). We can't decode the whole body as a
    /// String (attachment bytes aren't valid UTF-8), so we do byte-level
    /// boundary scanning instead. This matches RFC 2046 §5.1.1.
    static func splitMultipart(_ data: Data, boundary: String) -> [Data] {
        // The boundary marker is "--" + boundary, with optional CRLF prefix.
        // The closing boundary is "--" + boundary + "--".
        let delimiter = Data("--\(boundary)".utf8)
        guard !delimiter.isEmpty else { return [] }

        var children: [Data] = []
        var cursor = data.startIndex
        var inFirstPart = true  // Anything before the first delimiter is preamble.

        while cursor < data.endIndex {
            guard let delimRange = data.range(of: delimiter, in: cursor..<data.endIndex) else {
                break
            }
            // The part that ended is from `cursor` to `delimRange.lowerBound`
            // (minus the CRLF that precedes the delimiter, if present).
            if !inFirstPart {
                var end = delimRange.lowerBound
                // Strip trailing CRLF before the boundary marker.
                if end > cursor, data[data.index(before: end)] == 0x0A {
                    end = data.index(before: end)
                    if end > cursor, data[data.index(before: end)] == 0x0D {
                        end = data.index(before: end)
                    }
                }
                if end > cursor {
                    children.append(Data(data[cursor..<end]))
                }
            }
            inFirstPart = false

            // Check for closing boundary "--boundary--".
            var afterDelim = delimRange.upperBound
            if data.distance(from: afterDelim, to: data.endIndex) >= 2 {
                let twoAhead = data[afterDelim..<data.index(afterDelim, offsetBy: 2)]
                if twoAhead == Data("--".utf8) {
                    // Closing boundary — stop.
                    break
                }
            }
            // Skip CRLF after the delimiter to position cursor at the next
            // part's start.
            if afterDelim < data.endIndex, data[afterDelim] == 0x0D {
                afterDelim = data.index(after: afterDelim)
            }
            if afterDelim < data.endIndex, data[afterDelim] == 0x0A {
                afterDelim = data.index(after: afterDelim)
            }
            cursor = afterDelim
        }

        return children
    }

    // MARK: - Content-Disposition / filename resolution

    /// Parse a Content-Disposition header value into disposition and
    /// parameters.
    ///
    /// Example: `"attachment; filename=\"report.pdf\"; size=12345"` →
    /// (`"attachment"`, `["filename": "report.pdf", "size": "12345"]`).
    ///
    /// Returns `(nil, [:])` when the header is missing.
    static func parseContentDisposition(
        _ value: String?
    ) -> (String?, [String: String]) {
        guard let value = value else { return (nil, [:]) }
        let (disposition, params) = parseContentType(value)  // reuse same grammar
        return (disposition.isEmpty ? nil : disposition, params)
    }

    /// Resolve the attachment filename, preferring Content-Disposition
    /// `filename*=` (RFC 5987), then Content-Disposition `filename=`, then
    /// Content-Type `name=`.
    ///
    /// RFC 2231 continuation (`filename*0`, `filename*1`) is also
    /// supported: multi-segment filenames are concatenated in numeric
    /// order and percent-decoded if any segment has the trailing `*`.
    ///
    /// **#99 — nested RFC 2047 decode**: Outlook 16 Windows clients sometimes
    /// double-encode Chinese filenames by embedding an RFC 2047 encoded-word
    /// inside the RFC 2231 percent-encoded payload (or inside a plain
    /// `filename=` value). After resolving the outer layer, this function
    /// runs an idempotent RFC 2047 second pass via `decodeRFC2047IfApplicable`
    /// — a partial in-place decode gated on the presence of at least one
    /// well-formed encoded-word (`decodeRFC2047` itself only rewrites
    /// well-formed encoded-words, so a literal `=?...` substring that lacks
    /// the closing `?encoding?text?=` structure, e.g. `report=?bogus.pdf`,
    /// survives untouched).
    static func resolveFilename(
        dispositionParams: [String: String],
        contentTypeParams: [String: String]
    ) -> String? {
        // 1. RFC 5987 encoded filename (highest priority).
        if let extValue = dispositionParams["filename*"] {
            let decoded = decodeRFC5987(extValue) ?? extValue
            return decodeRFC2047IfApplicable(decoded)
        }

        // 2. RFC 2231 continuation: filename*0, filename*1, filename*2...
        //    Segments with a trailing "*" are percent-encoded.
        let continuationKeys = dispositionParams.keys
            .filter { $0.hasPrefix("filename*") && $0 != "filename*" }
            .sorted { lhs, rhs in
                let li = continuationIndex(lhs) ?? 0
                let ri = continuationIndex(rhs) ?? 0
                return li < ri
            }
        if !continuationKeys.isEmpty {
            var assembled = ""
            var firstCharset: String?
            for key in continuationKeys {
                guard let segment = dispositionParams[key] else { continue }
                if key.hasSuffix("*") {
                    // Percent-encoded segment.
                    if key == continuationKeys.first, let parsed = splitRFC5987(segment) {
                        firstCharset = parsed.charset
                        assembled += parsed.encoded
                    } else {
                        assembled += segment
                    }
                } else {
                    assembled += segment
                }
            }
            let decoded = decodePercentEncoded(assembled, charset: firstCharset ?? "utf-8")
                ?? assembled
            return decodeRFC2047IfApplicable(decoded)
        }

        // 3. Content-Disposition filename= (plain).
        if let filename = dispositionParams["filename"] {
            return decodeRFC2047IfApplicable(filename)
        }

        // 4. Content-Type name= (legacy, pre-Content-Disposition).
        if let name = contentTypeParams["name"] {
            return decodeRFC2047IfApplicable(name)
        }

        return nil
    }

    /// RFC 2047 encoded-word grammar — a single well-formed encoded-word:
    ///
    /// ```
    /// =?charset?B|Q?text?=
    /// ```
    ///
    /// Used as a gate before the second-pass decode in `resolveFilename`: the
    /// value is decoded only when it **contains** at least one well-formed
    /// encoded-word. `RFC822Parser.decodeRFC2047` is a partial, in-place
    /// scanner — it decodes well-formed encoded-words wherever they appear and
    /// leaves everything else untouched (a malformed `=?…` that is not a
    /// complete encoded-word, e.g. `report=?bogus.pdf`, fails `parseEncodedWord`
    /// and survives verbatim; a base64-decode failure also re-emits the raw
    /// encoded-word) — so the gate is a **substring search**, not anchored to
    /// the whole string. Anchoring it (`^…$`) was too strict: it refused a
    /// legitimate `=?…?=.pdf` value (encoded basename + literal extension),
    /// which the pre-#115 raw-header-level scan used to decode — once #115
    /// moved decoding from the header layer to this per-parameter layer, a
    /// whole-string gate silently dropped that attachment class.
    private static let rfc2047EncodedWordPattern: NSRegularExpression? = {
        let pattern = #"=\?[^?\s]+\?[BQbq]\?[^?]*\?="#
        return try? NSRegularExpression(pattern: pattern)
    }()

    /// Apply `RFC822Parser.decodeRFC2047` (a partial, in-place encoded-word
    /// scanner) when `value` contains at least one well-formed RFC 2047
    /// encoded-word. See `rfc2047EncodedWordPattern` for the rationale.
    static func decodeRFC2047IfApplicable(_ value: String) -> String {
        guard let regex = rfc2047EncodedWordPattern else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard regex.firstMatch(in: value, range: range) != nil else { return value }
        return RFC822Parser.decodeRFC2047(value)
    }

    /// Parse RFC 5987 ext-value: `charset'language'percent-encoded`.
    /// Returns (charset, percent-encoded-value) or nil when malformed.
    static func splitRFC5987(_ value: String) -> (charset: String, encoded: String)? {
        let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return (String(parts[0]), String(parts[2]))
    }

    /// Decode a full RFC 5987 ext-value like `UTF-8''%E4%B8%AD%E6%96%87.pdf`.
    static func decodeRFC5987(_ extValue: String) -> String? {
        guard let (charset, encoded) = splitRFC5987(extValue) else { return nil }
        return decodePercentEncoded(encoded, charset: charset)
    }

    /// Decode a percent-encoded string under the given charset.
    static func decodePercentEncoded(_ encoded: String, charset: String) -> String? {
        // Build the byte sequence from %XX pairs + plain chars.
        var bytes: [UInt8] = []
        var idx = encoded.startIndex
        while idx < encoded.endIndex {
            let ch = encoded[idx]
            if ch == "%" {
                let hexStart = encoded.index(after: idx)
                guard encoded.distance(from: hexStart, to: encoded.endIndex) >= 2 else {
                    return nil
                }
                let hexEnd = encoded.index(hexStart, offsetBy: 2)
                let hex = String(encoded[hexStart..<hexEnd])
                guard let byte = UInt8(hex, radix: 16) else { return nil }
                bytes.append(byte)
                idx = hexEnd
            } else if let scalar = ch.asciiValue {
                bytes.append(scalar)
                idx = encoded.index(after: idx)
            } else {
                // Non-ASCII literal — re-encode as UTF-8 bytes.
                bytes.append(contentsOf: String(ch).utf8)
                idx = encoded.index(after: idx)
            }
        }

        let textEncoding = RFC822Parser.stringEncoding(for: charset)
        return String(data: Data(bytes), encoding: textEncoding)
            ?? String(data: Data(bytes), encoding: .utf8)
    }

    /// Extract the numeric index from a continuation key like `filename*3*`
    /// or `filename*0`. Returns nil for the bare `filename*` key.
    private static func continuationIndex(_ key: String) -> Int? {
        // key format: filename*<N>[*]
        let afterStar = key.dropFirst("filename*".count)
        let digits = afterStar.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    // MARK: - Part Parsing

    private static func parsePart(
        _ data: Data,
        contentType: String,
        encoding: String
    ) -> ParsedEmailContent {
        let (mimeType, params) = parseContentType(contentType)

        if mimeType.hasPrefix("multipart/") {
            guard let boundary = params["boundary"] else {
                return ParsedEmailContent(textBody: nil, htmlBody: nil)
            }
            return parseMultipart(data, boundary: boundary)
        }

        // Decode transfer encoding
        let decoded = decodeTransferEncoding(data, encoding: encoding)
        let charset = params["charset"] ?? "utf-8"
        let textEncoding = RFC822Parser.stringEncoding(for: charset)
        let text = String(data: decoded, encoding: textEncoding)
            ?? String(data: decoded, encoding: .utf8)
            ?? String(data: decoded, encoding: .ascii)

        if mimeType == "text/html" {
            return ParsedEmailContent(textBody: nil, htmlBody: text)
        } else if mimeType.hasPrefix("text/") {
            return ParsedEmailContent(textBody: text, htmlBody: nil)
        }
        // Non-text parts (attachments, images) — skip
        return ParsedEmailContent(textBody: nil, htmlBody: nil)
    }

    // MARK: - Multipart

    private static func parseMultipart(
        _ data: Data,
        boundary: String
    ) -> ParsedEmailContent {
        let boundaryMarker = "--\(boundary)"
        let endMarker = "--\(boundary)--"

        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii) else {
            return ParsedEmailContent(textBody: nil, htmlBody: nil)
        }

        var textBody: String?
        var htmlBody: String?

        let parts = text.components(separatedBy: boundaryMarker)

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("--") { continue }

            // Each part has its own headers + body
            let partData = Data(part.utf8)
            guard let splitOffset = RFC822Parser.headerBodySplitOffset(in: partData) else {
                continue
            }

            let partHeaders = RFC822Parser.parseHeaders(from: partData)
            let partBody = partData[splitOffset...]

            let partCT = partHeaders["content-type"] ?? "text/plain"
            let partCTE = partHeaders["content-transfer-encoding"] ?? "7bit"

            let result = parsePart(Data(partBody), contentType: partCT, encoding: partCTE)

            if let t = result.textBody, textBody == nil {
                textBody = t
            }
            if let h = result.htmlBody, htmlBody == nil {
                htmlBody = h
            }
        }

        return ParsedEmailContent(textBody: textBody, htmlBody: htmlBody)
    }

    // MARK: - Content-Type Parsing

    /// Parse a Content-Type header value into MIME type and parameters.
    static func parseContentType(_ value: String) -> (String, [String: String]) {
        let parts = value.components(separatedBy: ";")
        let mimeType = parts[0].trimmingCharacters(in: .whitespaces).lowercased()

        var params: [String: String] = [:]
        for i in 1..<parts.count {
            let param = parts[i].trimmingCharacters(in: .whitespaces)
            if let eqIdx = param.firstIndex(of: "=") {
                let key = String(param[param.startIndex..<eqIdx])
                    .trimmingCharacters(in: .whitespaces).lowercased()
                var val = String(param[param.index(after: eqIdx)...])
                    .trimmingCharacters(in: .whitespaces)
                // Remove surrounding quotes
                if val.hasPrefix("\"") && val.hasSuffix("\"") {
                    val = String(val.dropFirst().dropLast())
                }
                params[key] = val
            }
        }
        return (mimeType, params)
    }

    // MARK: - Transfer Encoding

    private static func decodeTransferEncoding(_ data: Data, encoding: String) -> Data {
        switch encoding.lowercased() {
        case "base64":
            let cleaned = String(data: data, encoding: .ascii)?
                .replacingOccurrences(of: "\r\n", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: " ", with: "")
                ?? ""
            return Data(base64Encoded: cleaned) ?? data

        case "quoted-printable":
            guard let text = String(data: data, encoding: .ascii) else { return data }
            return RFC822Parser.decodeQuotedPrintableBytes(text) ?? data

        case "7bit", "8bit", "binary":
            return data

        default:
            return data
        }
    }
}
