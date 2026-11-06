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
/// `Tests/CheAppleMailMCPTests/NoAsciiDecodingGuardTests.swift` fails if
/// `encoding: .ascii` comes back in `Sources/`.
enum ByteDecoding {

    /// True when every byte is below `0x80`.
    static func isASCII(_ data: Data) -> Bool {
        !data.contains { $0 >= 0x80 }
    }

    /// One scalar per byte. Total, lossless and free of Foundation's encoding
    /// tables: the mapping back to the same bytes is `UInt8(scalar.value)`.
    static func latin1String(_ data: Data) -> String {
        String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) }))
    }

    /// Strict UTF-8 when the bytes are valid, Latin-1 otherwise. Total.
    static func utf8OrLatin1(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? latin1String(data)
    }

    /// `String(data:encoding:)` for a charset label resolved by
    /// `RFC822Parser.stringEncoding(for:)`.
    ///
    /// An ASCII label cannot name a non-ASCII byte, so such bytes are read as
    /// UTF-8 when they are valid UTF-8 and as Latin-1 otherwise (the rule
    /// `MIMEParser.decodeBodyText` already applies to bodies, #538). For an
    /// ASCII label the result is therefore never `nil`.
    static func string(from data: Data, encoding: String.Encoding) -> String? {
        encoding == .ascii ? utf8OrLatin1(data) : String(data: data, encoding: encoding)
    }
}
