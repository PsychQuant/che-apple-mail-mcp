import Foundation

/// A fully-decoded MIME part from an RFC 822 / RFC 2045 message body.
///
/// `MIMEPart` is a **non-lossy** representation of a single part — it preserves
/// both the raw bytes and the transfer-decoded payload, along with structural
/// metadata (content type, disposition, filename). This is different from
/// `ParsedEmailContent`, which only surfaces `textBody` / `htmlBody` and
/// discards non-text parts.
///
/// ## Field semantics
///
/// - `headers`: part-level headers with **lowercased keys** (same convention
///   as `RFC822Parser.parseHeaders`).
/// - `contentType`: the MIME type only (e.g., `"image/png"`) — the parameters
///   (boundary, charset, name) live in `contentTypeParams`.
/// - `contentTypeParams`: parsed `Content-Type` parameters with lowercased
///   keys. For multipart parts this holds `boundary`. For attachments it
///   often holds `name` (the historical filename location before
///   Content-Disposition became standard).
/// - `contentDisposition`: the disposition value only (`"attachment"`,
///   `"inline"`, or `nil` when the header is absent). Parameters like
///   `filename` and `size` are extracted into dedicated fields — not kept
///   here — so callers don't need to re-parse a second parameter map.
/// - `filename`: the resolved attachment filename, with RFC 2231 / RFC 5987
///   continuation and percent-encoding already decoded. If neither
///   `Content-Disposition: filename` nor `Content-Type: name` was present,
///   this is `nil`.
/// - `rawBytes`: the part body before transfer decoding (useful for debug
///   and roundtrip tests).
/// - `decodedData`: the part body after transfer decoding (base64,
///   quoted-printable, 7bit/8bit/binary passthrough). For binary attachments
///   this is what you write to disk.
///
/// ## Design notes
///
/// - All fields are `let` constants; `MIMEPart` is a pure value type.
/// - `Sendable` conformance means parts can cross concurrency domains
///   freely, which is useful if a caller wants to parallelize part-level
///   operations (e.g., hash or virus-scan in parallel).
/// - `Equatable` is synthesized and compares all fields by value; two parts
///   with identical bytes and metadata are equal regardless of the original
///   message they came from.
/// - `decodedData` is **eagerly** computed during parsing. Lazy decoding
///   would require `mutating get` or a class wrapper, both of which would
///   break `Sendable` or value semantics.
public struct MIMEPart: Sendable, Equatable {
    public let headers: [String: String]
    public let contentType: String
    public let contentTypeParams: [String: String]
    public let contentDisposition: String?
    public let filename: String?
    public let rawBytes: Data
    public let decodedData: Data

    public init(
        headers: [String: String],
        contentType: String,
        contentTypeParams: [String: String],
        contentDisposition: String?,
        filename: String?,
        rawBytes: Data,
        decodedData: Data
    ) {
        self.headers = headers
        self.contentType = contentType
        self.contentTypeParams = contentTypeParams
        self.contentDisposition = contentDisposition
        self.filename = filename
        self.rawBytes = rawBytes
        self.decodedData = decodedData
    }
}
