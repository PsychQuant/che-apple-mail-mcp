import Foundation

/// Low-level parser for Apple Mail's .emlx file container format.
///
/// An .emlx file consists of:
/// 1. A decimal integer string (byte count of the RFC 822 message data)
/// 2. A newline (0x0A)
/// 3. Exactly that many bytes of raw RFC 822 message data
/// 4. Optionally, Apple plist XML metadata (ignored by this parser)
///
/// This enum extracts only the raw message data; it does **not**
/// parse RFC 822 headers or MIME structure.
public enum EmlxFormat {

    // MARK: - Constants

    private static let newline: UInt8 = 0x0A

    // MARK: - Public API

    /// Parse an .emlx file and extract the raw RFC 822 message data.
    /// - Parameter data: The raw file contents.
    /// - Returns: The RFC 822 message data bytes.
    /// - Throws: `MailSQLiteError.emlxParseFailed` if the format is invalid.
    public static func extractMessageData(from data: Data) throws -> Data {
        // 1. Find the first newline
        guard let newlineIndex = data.firstIndex(of: newline) else {
            throw MailSQLiteError.emlxParseFailed(
                "No newline found; cannot locate byte count header"
            )
        }

        // 2. Parse the text before the newline as a byte count
        let headerBytes = data[data.startIndex..<newlineIndex]
        guard let headerString = String(bytes: headerBytes, encoding: .utf8),
              let byteCount = Int(headerString.trimmingCharacters(in: .whitespaces)),
              byteCount >= 0
        else {
            let preview = String(
                bytes: data[data.startIndex..<min(data.startIndex + 40, data.endIndex)],
                encoding: .utf8
            ) ?? "<binary>"
            throw MailSQLiteError.emlxParseFailed(
                "Invalid byte count header: \(preview)"
            )
        }

        // 3. Extract exactly byteCount bytes after the newline
        let messageStart = data.index(after: newlineIndex)
        let messageEnd = data.index(messageStart, offsetBy: byteCount, limitedBy: data.endIndex)

        guard let end = messageEnd else {
            throw MailSQLiteError.emlxParseFailed(
                "Insufficient data: expected \(byteCount) bytes after header, "
                + "but only \(data.distance(from: messageStart, to: data.endIndex)) available"
            )
        }

        return data[messageStart..<end]
    }
}
