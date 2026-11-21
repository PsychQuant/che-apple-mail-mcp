import Foundation

/// Removes the `Bcc` header fields of a stored draft before it is submitted
/// (#742). Envelope recipients carry the Bcc addresses; the bytes the
/// recipients receive must not name them (RFC 5322 section 3.6.3).
///
/// Only the header section is read, and every byte that is not part of a
/// `Bcc` field is kept. When a line could hide a `Bcc` field from this reader,
/// the draft is refused instead of sent: a header line that does not end in
/// CRLF, a `Resent-Bcc` field, a continuation line with no field above it, a
/// line that is neither a field nor a continuation, or a field name that is not
/// RFC 5322 `ftext` (empty, or holding a byte outside printable ASCII).
enum BccRemoval {
    struct Refused: Error, CustomStringConvertible {
        let reason: String
        var description: String { "the draft's header cannot be sent safely: \(reason)" }
    }

    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A

    /// The lowercased names of the header fields, in order, each once per field.
    /// Throws for the same headers `strip` refuses.
    static func fieldNames(in message: Data) throws -> [String] {
        try parse([UInt8](message)).fields.map(\.name)
    }

    /// Each header field as its lowercased name and its unfolded value (the
    /// bytes after the colon, continuation lines joined), in order.
    static func fields(in message: Data) throws -> [(name: String, value: String)] {
        try parse([UInt8](message)).fields.map { field in
            var bytes: [UInt8] = []
            for (index, line) in field.lines.enumerated() {
                if index == 0, let colon = line.firstIndex(of: 0x3A) {
                    bytes += line[line.index(after: colon)...]
                } else {
                    bytes += line
                }
            }
            return (field.name, String(decoding: bytes, as: UTF8.self))
        }
    }

    /// How many addresses an address-list field value names: its `@` signs
    /// outside quoted strings and comments. Not a parser; compared with the
    /// server's envelope, a difference means the envelope left something out.
    static func addressCount(inFieldValue value: String) -> Int {
        var count = 0, depth = 0, quoted = false, escaped = false
        for scalar in value.unicodeScalars {
            if escaped { escaped = false; continue }
            switch scalar {
            case "\\" where quoted || depth > 0: escaped = true
            case "\"" where depth == 0: quoted.toggle()
            case "(" where !quoted: depth += 1
            case ")" where !quoted && depth > 0: depth -= 1
            case "@" where !quoted && depth == 0: count += 1
            default: break
            }
        }
        return count
    }

    static func strip(_ message: Data) throws -> Data {
        let bytes = [UInt8](message)
        let parsed = try parse(bytes)
        var kept: [UInt8] = []
        for field in parsed.fields where field.name != "bcc" {
            for line in field.lines { kept += line; kept += [cr, lf] }
        }
        kept += [cr, lf]
        kept += bytes[parsed.bodyStart...]
        return Data(kept)
    }

    private struct Field {
        let name: String
        var lines: [ArraySlice<UInt8>]
    }

    private static func parse(_ bytes: [UInt8]) throws -> (fields: [Field], bodyStart: Int) {
        var lines: [ArraySlice<UInt8>] = []   // header lines without their CRLF
        var index = 0
        var headerEnd: Int?
        while index < bytes.count {
            var end = index
            while end < bytes.count, bytes[end] != cr, bytes[end] != lf { end += 1 }
            guard end < bytes.count else { break }
            if bytes[end] == lf { throw Refused(reason: "a line feed without a carriage return") }
            guard end + 1 < bytes.count, bytes[end + 1] == lf else {
                throw Refused(reason: "a carriage return without a line feed")
            }
            if end == index {           // the blank line that ends the header section
                headerEnd = end + 2
                break
            }
            lines.append(bytes[index..<end])
            index = end + 2
        }
        guard let bodyStart = headerEnd else {
            throw Refused(reason: "no blank line marks the end of the header section")
        }

        var fields: [Field] = []
        for line in lines {
            let first = line[line.startIndex]
            if first == 0x20 || first == 0x09 {          // a continuation line
                guard !fields.isEmpty else { throw Refused(reason: "a continuation line with no field above it") }
                fields[fields.count - 1].lines.append(line)
                continue
            }
            guard let colon = line.firstIndex(of: 0x3A) else {
                throw Refused(reason: "a line that is not a header field")
            }
            let name = line[line.startIndex..<colon]
            // ftext: printable US-ASCII except the colon (RFC 5322 section 3.6.8).
            guard !name.isEmpty, name.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
                throw Refused(reason: "a field name that is empty or holds a byte outside printable ASCII")
            }
            let lowered = String(decoding: name, as: UTF8.self).lowercased()
            if lowered == "resent-bcc" { throw Refused(reason: "a Resent-Bcc field") }
            fields.append(Field(name: lowered, lines: [line]))
        }
        return (fields, bodyStart)
    }
}
