import Foundation

/// Byte-to-`String` steps that say what they mean instead of relying on how
/// `String(data:encoding: .ascii)` treats a non-ASCII byte (#561).
///
/// That behaviour depends on the SDK the executable was linked against, which
/// Foundation reads from `LC_BUILD_VERSION`. The shipped binary is stamped
/// sdk 13.0 and gets the legacy behaviour: the call succeeds and maps each byte
/// to a Latin-1 scalar. `swift test` runs inside `xctest`, stamped with the
/// current SDK, where the same call returns `nil`. Code that used `.ascii` as a
/// validity check or as a byte-to-string step therefore did different things in
/// the tests and in the product, which is how #538 passed the suite and shipped.
///
/// `Tests/CheAppleMailMCPTests/NoAsciiDecodingGuardTests.swift` fails on the
/// spellings it lists; it is a text scan, not a proof that no path decodes ASCII.
enum ByteDecoding {

    /// True when every byte is below `0x80`.
    static func isASCII(_ data: Data) -> Bool {
        !data.contains { $0 >= 0x80 }
    }

    /// One scalar per byte: total and lossless, the mapping back to the same
    /// bytes is `UInt8(scalar.value)`. `.isoLatin1` was measured total under
    /// both SDK stamps; the fallback keeps that from being an assumption.
    static func latin1String(_ data: Data) -> String {
        String(data: data, encoding: .isoLatin1)
            ?? String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) }))
    }

    /// The bytes as UTF-8, or `nil` unless they are valid UTF-8 (overlong forms,
    /// surrogates and truncated sequences are invalid).
    ///
    /// The check belongs to the standard library, not to a Foundation encoding
    /// conversion: `String(decoding:as:)` repairs invalid input, so the bytes
    /// survive unchanged exactly when they were valid. A leading byte order mark
    /// is dropped, as `String(data:encoding: .utf8)` does.
    static func strictUTF8(_ data: Data) -> String? {
        var decoded = String(decoding: data, as: UTF8.self)
        guard decoded.utf8.elementsEqual(data) else { return nil }
        if decoded.unicodeScalars.first == "\u{FEFF}" { decoded.unicodeScalars.removeFirst() }
        return decoded
    }

    /// Strict UTF-8 when the bytes are valid, Latin-1 otherwise. Total.
    static func utf8OrLatin1(_ data: Data) -> String {
        strictUTF8(data) ?? latin1String(data)
    }

    /// `String(data:encoding:)` for a charset label resolved by
    /// `RFC822Parser.stringEncoding(for:)`.
    ///
    /// An ASCII label cannot name a non-ASCII byte, so such bytes are read as
    /// UTF-8 when they are valid UTF-8 and as Latin-1 otherwise (the rule
    /// `MIMEParser.decodeBodyText` already applies to bodies, #538). For an
    /// ASCII label the result is therefore never `nil`. Other multi-byte
    /// charsets still rely on Foundation's conversion failing on bytes it
    /// cannot decode: that is the only implementation of those tables here.
    static func string(from data: Data, encoding: String.Encoding) -> String? {
        switch encoding {
        case .ascii: return utf8OrLatin1(data)
        case .utf8: return strictUTF8(data)
        default: return String(data: data, encoding: encoding)
        }
    }
}
