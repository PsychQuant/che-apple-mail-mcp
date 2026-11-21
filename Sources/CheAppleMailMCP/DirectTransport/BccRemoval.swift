import Foundation

/// Removes the `Bcc` header fields of a stored draft before it is submitted
/// (#742). Envelope recipients carry the Bcc addresses; the bytes the
/// recipients receive must not name them (RFC 5322 section 3.6.3).
///
/// Only the header section is read, and every byte that is not part of a
/// `Bcc` field is kept. When a line could hide a `Bcc` field from this reader,
/// the draft is refused instead of sent: a header line that does not end in
/// CRLF, a `Resent-Bcc` field, a continuation line with no field above it, a
/// line that is neither a field nor a continuation, or a field name with white
/// space in it.
enum BccRemoval {
    struct Refused: Error, CustomStringConvertible {
        let reason: String
        var description: String { "the draft's header cannot be sent safely: \(reason)" }
    }

    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A

    static func strip(_ message: Data) throws -> Data {
        let bytes = [UInt8](message)
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

        var kept: [UInt8] = []
        var dropping = false
        var sawField = false
        for line in lines {
            let first = line[line.startIndex]
            if first == 0x20 || first == 0x09 {          // a continuation line
                guard sawField else { throw Refused(reason: "a continuation line with no field above it") }
                if !dropping { kept += line; kept += [cr, lf] }
                continue
            }
            guard let colon = line.firstIndex(of: 0x3A) else {
                throw Refused(reason: "a line that is not a header field")
            }
            let name = line[line.startIndex..<colon]
            if name.contains(where: { $0 == 0x20 || $0 == 0x09 }) {
                throw Refused(reason: "a field name with white space in it")
            }
            let lowered = String(decoding: name, as: UTF8.self).lowercased()
            if lowered == "resent-bcc" { throw Refused(reason: "a Resent-Bcc field") }
            sawField = true
            dropping = lowered == "bcc"
            if !dropping { kept += line; kept += [cr, lf] }
        }
        kept += [cr, lf]
        kept += bytes[bodyStart...]
        return Data(kept)
    }
}
