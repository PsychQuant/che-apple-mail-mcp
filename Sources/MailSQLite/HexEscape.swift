import Foundation

/// The two-character escape of quoted-printable (`=XX`) and percent encoding
/// (`%XX`), read the one way both mean it: two ASCII hex digits and nothing else.
///
/// `UInt8(hex, radix: 16)` is not that. It accepts a leading sign (`"+5"` is 5,
/// `"-0"` is 0, `"+a"` is 10), so `=+5` decoded to a control byte instead of
/// staying text (#641). `Character.hexDigitValue` is not that either: it reads
/// the fullwidth digits too (`"０".hexDigitValue == 0`), so `=０５` would decode.
/// `Sources/` therefore has no `radix: 16` parse, which
/// `NoRadix16HexParsingGuardTests` scans for.
///
/// `public` so the AppleScript fallback in the executable target reads an escape
/// the same way as the parsers here. `MailSQLite` is not a package product, so
/// this adds no external API.
public enum HexEscape {

    /// The value of one ASCII hex digit (`0-9`, `A-F`, `a-f`), `nil` for anything else.
    ///
    /// A `Character` is a grapheme cluster: `"5\u{301}"` is one `Character` with no
    /// `asciiValue`, and `"\r\n"` is one whose `asciiValue` is `0x0A`. Neither is a digit.
    public static func digit(_ character: Character) -> UInt8? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return ascii - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return ascii - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return ascii - UInt8(ascii: "a") + 10
        default: return nil
        }
    }

    /// The byte named by two ASCII hex digits, `nil` when either character is not one.
    public static func byte(_ high: Character, _ low: Character) -> UInt8? {
        guard let high = digit(high), let low = digit(low) else { return nil }
        return high << 4 | low
    }
}
