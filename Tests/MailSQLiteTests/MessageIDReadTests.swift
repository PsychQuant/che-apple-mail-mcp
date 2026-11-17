import XCTest
@testable import MailSQLite

/// #682: the header-only Message-ID reader returns the value `get_email` reports (the value
/// `readEmail` extracts), for every message shape, at every chunk size, and reads only as much of
/// the file as it needs.
final class MessageIDReadTests: XCTestCase {

    /// What `readEmail` does with the same bytes: whole-file read, prefix strip, `parseHeaders`.
    private func oracle(path: String) throws -> String {
        let file = try Data(contentsOf: URL(fileURLWithPath: path))
        let message = try EmlxFormat.extractMessageData(from: file)
        return RFC822Parser.parseHeaders(from: message)["message-id"] ?? ""
    }

    // spec-example: sqlite-query-engine / The value equals the one get_email reports
    func testReaderEqualsTheWholeFileParseForEverySampleAndChunkSize() throws {
        let store = try MessageIDStore(testCase: self)
        for (index, sample) in MessageIDSamples.all.enumerated() {
            let path = try store.write(rowId: index + 1, message: sample.message)
            let expected = try oracle(path: path)
            for chunk in [1, 2, 3, 5, 7, 64, 1024, 32_768] where sample.message.count < 20_000 || chunk >= 64 {
                XCTAssertEqual(try EmlxParser.readMessageID(atPath: path, chunkSize: chunk), expected,
                               "\(sample.name) chunk=\(chunk)")
            }
        }
    }

    func testReaderEqualsReadEmailThroughTheStore() throws {
        let store = try MessageIDStore(testCase: self)
        try store.withStoragePath {
            for (index, sample) in MessageIDSamples.all.enumerated() {
                let rowId = index + 1
                let path = try store.write(rowId: rowId, message: sample.message)
                let viaGetEmail = try EmlxParser.readEmail(rowId: rowId, mailboxURL: MessageIDStore.mailboxURL()).messageId
                let viaSource = try EmlxParser.readEmail(rowId: rowId, mailboxURL: MessageIDStore.mailboxURL(), format: "source").messageId
                let viaReader = try EmlxParser.readMessageID(atPath: path)
                XCTAssertEqual(viaReader, viaGetEmail, sample.name)
                XCTAssertEqual(viaSource, viaGetEmail, sample.name)
            }
        }
    }

    func testKnownValues() throws {
        let store = try MessageIDStore(testCase: self)
        func value(_ name: String) throws -> String {
            let (index, sample) = try XCTUnwrap(MessageIDSamples.all.enumerated().first { $0.element.name == name })
            return try EmlxParser.readMessageID(atPath: try store.write(rowId: index + 1, message: sample.message), chunkSize: 16)
        }
        XCTAssertEqual(try value("plain"), "<plain@example.invalid>")
        XCTAssertEqual(try value("duplicate"), "<second@example.invalid>", "the last header wins, as in get_email")
        XCTAssertEqual(try value("none"), "", "no header is the empty string")
        XCTAssertEqual(try value("empty-value"), "")
        XCTAssertEqual(try value("empty-message"), "")
        XCTAssertEqual(try value("no-brackets"), "bare.value@example.invalid")
        XCTAssertEqual(try value("folded"), "<folded.part1 .part2@example.invalid>")
    }

    // The reader must stop at the end of the header block instead of loading the file.
    func testAHeaderBlockEndingEarlyReadsOnlyThatFarInChunks() throws {
        let store = try MessageIDStore(testCase: self)
        let (index, sample) = try XCTUnwrap(MessageIDSamples.all.enumerated().first { $0.element.name == "headers-only-attachment-body" })
        let path = try store.write(rowId: index + 1, message: sample.message)
        XCTAssertGreaterThan(sample.message.count, 300_000)
        var total = 0
        let value = try EmlxParser.readMessageID(atPath: path, chunkSize: 4096, bytesRead: { total += $0 })
        XCTAssertEqual(value, "<att@example.invalid>")
        XCTAssertLessThanOrEqual(total, 4096 + 4096, "one chunk of the length line plus one chunk of message: \(total)")
    }

    // A slice whose start index is not 0 (the shape `extractMessageData` returns).
    func testHelpersAreSafeOnASliceWithANonZeroStartIndex() throws {
        let message = Data("Subject: s\r\nMessage-ID: <slice@example.invalid>\r\n\r\nbody".utf8)
        let file = Data("\(message.count)\n".utf8) + message + Data("\n<plist/>\n".utf8)
        let slice = try EmlxFormat.extractMessageData(from: file)
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(EmlxParser.messageID(inMessageData: slice), "<slice@example.invalid>")
        // The length-line parser on a slice of a bigger buffer.
        let padded = Data(repeating: 0x58, count: 7) + file
        let sub = padded[7...]
        XCTAssertNotEqual(sub.startIndex, 0)
        let prefix = try EmlxFormat.parseLengthPrefix(from: sub)
        XCTAssertEqual(prefix.byteCount, message.count)
        XCTAssertEqual(prefix.messageStart, sub.startIndex + "\(message.count)\n".utf8.count)
        XCTAssertEqual(try EmlxFormat.extractMessageData(from: sub), message)
    }

    // MARK: - The cap on what is looked at (#682 security lens A)

    private func read(_ message: Data, cap: Int, chunk: Int = 64) throws -> (value: String?, error: Error?, total: Int) {
        let store = try MessageIDStore(testCase: self)
        let path = try store.write(rowId: 1, message: message)
        var total = 0
        do {
            let v = try EmlxParser.readMessageID(atPath: path, chunkSize: chunk, maxHeaderBytes: cap, bytesRead: { total += $0 })
            return (v, nil, total)
        } catch { return (nil, error, total) }
    }

    func testAnLFOnlyMessageIsReadWithinTheCapAndEqualsGetEmail() throws {
        let message = Data("Subject: s\nMessage-ID: <lf@example.invalid>\n\n".utf8) + Data(repeating: 0x42, count: 2_000_000)
        let r = try read(message, cap: 1024)
        XCTAssertEqual(r.value, "<lf@example.invalid>")
        XCTAssertLessThanOrEqual(r.total, 4096 + 1024, "bytes actually read: \(r.total)")
        // get_email's value for the same bytes
        XCTAssertEqual(EmlxParser.messageID(inMessageData: message), r.value, "equals the whole-message parse")
    }

    func testAMessageWithNoSeparatorIsUnreadableAndReadsOnlyTheCap() throws {
        let message = Data("Message-ID: <x@example.invalid>\r\n".utf8) + Data(repeating: 0x41, count: 2_000_000)
        let r = try read(message, cap: 1024)
        XCTAssertTrue(r.error is EmlxParser.HeaderBlockTooLarge, "\(String(describing: r.error)) \(String(describing: r.value))")
        XCTAssertLessThanOrEqual(r.total, 4096 + 1024, "bytes actually read: \(r.total)")
    }

    func testAShortMessageWithNoSeparatorIsParsedWhole() throws {
        let r = try read(Data("Subject: s\r\nMessage-ID: <short@example.invalid>".utf8), cap: 1024)
        XCTAssertEqual(r.value, "<short@example.invalid>")
    }

    func testAHeaderBlockJustUnderAndJustOverTheCap() throws {
        func message(headerBytes: Int, separator: String) -> Data {
            let id = "Message-ID: <cap@example.invalid>\r\n"
            let pad = String(repeating: "x", count: max(headerBytes - id.utf8.count - separator.utf8.count - 4, 0))
            return Data((id + "X: " + pad + "\r\n" + separator + String(repeating: "b", count: 5000)).utf8)
        }
        for separator in ["\r\n", "\n"] {
            // "\r\n" completes CRLF CRLF after the X line; for "\n" the block ends in a bare-LF blank line.
            let under = try read(message(headerBytes: 900, separator: separator), cap: 1000)
            XCTAssertEqual(under.value, "<cap@example.invalid>", "under cap, separator \(separator.debugDescription)")
            let over = try read(message(headerBytes: 1100, separator: separator), cap: 1000)
            XCTAssertTrue(over.error is EmlxParser.HeaderBlockTooLarge, "over cap, separator \(separator.debugDescription): \(String(describing: over.value))")
            XCTAssertLessThanOrEqual(over.total, 4096 + 1000)
        }
    }

    func testAHostileLengthLineReadsNothingBeyondTheFirstBlock() throws {
        let store = try MessageIDStore(testCase: self)
        for line in ["9223372036854775807", "99999999999999999999", "-1", "  12  x"] {
            let url = store.root.appendingPathComponent("h-\(abs(line.hashValue)).emlx")
            try (Data((line + "\n").utf8) + Data(repeating: 0x41, count: 200_000)).write(to: url)
            var total = 0
            XCTAssertThrowsError(try EmlxParser.readMessageID(atPath: url.path, bytesRead: { total += $0 }), line)
            XCTAssertLessThanOrEqual(total, 4096, line)
        }
    }


    // MARK: - Where the reader and get_email differ (recorded by tests, see the pull request)

    /// What `get_email` reports (`readEmail`) next to what the reader returns, for the same bytes.
    private func both(_ message: Data, cap: Int) throws -> (reader: String?, getEmail: String) {
        let store = try MessageIDStore(testCase: self)
        let path = try store.write(rowId: 1, message: message)
        let getEmail = try store.withStoragePath {
            try EmlxParser.readEmail(rowId: 1, mailboxURL: MessageIDStore.mailboxURL()).messageId
        }
        return (try? EmlxParser.readMessageID(atPath: path, chunkSize: 64, maxHeaderBytes: cap), getEmail)
    }

    /// D1: larger than the cap, a bare-LF blank line inside it, a CRLF CRLF only later. The reader
    /// ends the header block at the first blank line; `get_email`'s parser prefers a CRLF blank
    /// line anywhere in the message and so reads the lines between the two as headers.
    func testDifferenceD1BareLFBlankLineInsideTheCapAndACRLFBlankLineBeyondIt() throws {
        let filler = String(repeating: "filler line\n", count: 400)   // > the 1024-byte cap
        let message = Data(("Message-ID: <header@example.invalid>\n\nMessage-ID: <between@example.invalid>\n"
            + filler + "\r\n\r\nafter").utf8)
        XCTAssertGreaterThan(message.count, 1024 * 2)
        let r = try both(message, cap: 1024)
        XCTAssertEqual(r.reader, "<header@example.invalid>")
        XCTAssertEqual(r.getEmail, "<between@example.invalid>")
        XCTAssertNotEqual(r.reader, r.getEmail, "the recorded difference")
        // Inside the cap the two agree: the same bytes with a cap that reaches the CRLF CRLF.
        let wide = try both(message, cap: 1_000_000)
        XCTAssertEqual(wide.reader, wide.getEmail)
    }

    /// D2: lone-CR line ends, larger than the cap: the reader has no key (no separator it can use
    /// inside the cap); `get_email` parses the whole message as headers.
    func testDifferenceD2LoneCRMessageLargerThanTheCap() throws {
        let message = Data(("Message-ID: <cr@example.invalid>\r" + String(repeating: "X-Pad: yyyyyyyy\r", count: 300)).utf8)
        XCTAssertGreaterThan(message.count, 2048)
        let r = try both(message, cap: 1024)
        XCTAssertNil(r.reader)
        XCTAssertEqual(r.getEmail, "<cr@example.invalid>")
        let wide = try both(message, cap: 1_000_000)
        XCTAssertEqual(wide.reader, wide.getEmail)
    }

    func testTheCapBoundaryIsExact() throws {
        func message(total: Int) -> Data {
            let head = "Message-ID: <b@example.invalid>\r\nX: "
            let tail = "\r\n\r\n"
            let pad = String(repeating: "p", count: total - head.utf8.count - tail.utf8.count)
            return Data((head + pad + tail + String(repeating: "b", count: 5000)).utf8)
        }
        XCTAssertEqual(try read(message(total: 1000), cap: 1000).value, "<b@example.invalid>", "separator ends exactly at the cap")
        XCTAssertTrue(try read(message(total: 1001), cap: 1000).error is EmlxParser.HeaderBlockTooLarge, "one byte past it")
    }

    func testANonPositiveCapReadsNothingOfTheMessage() throws {
        for cap in [0, -5] {
            let r = try read(Data("Message-ID: <z@example.invalid>\r\n\r\nbody".utf8), cap: cap)
            XCTAssertTrue(r.error is EmlxParser.HeaderBlockTooLarge, "cap \(cap)")
            XCTAssertLessThanOrEqual(r.total, 4096)
        }
        XCTAssertEqual(try read(Data(), cap: 0).value, "", "an empty message has no header whatever the cap")
    }

    // MARK: - Unreadable

    func testAMissingFileThrows() throws {
        let store = try MessageIDStore(testCase: self)
        XCTAssertThrowsError(try EmlxParser.readMessageID(atPath: store.root.appendingPathComponent("nope.emlx").path))
    }

    func testATruncatedFileThrowsLikeReadEmail() throws {
        let store = try MessageIDStore(testCase: self)
        let path = store.root.appendingPathComponent("trunc.emlx")
        try Data("500\nSubject: s\r\nMessage-ID: <t@example.invalid>\r\n\r\nshort".utf8).write(to: path)
        XCTAssertThrowsError(try EmlxParser.readMessageID(atPath: path.path))
        XCTAssertThrowsError(try EmlxFormat.extractMessageData(from: try Data(contentsOf: path)))
    }

    func testABadLengthLineThrows() throws {
        let store = try MessageIDStore(testCase: self)
        let a = store.root.appendingPathComponent("bad1.emlx")
        try Data("not-a-number\nSubject: s\r\n\r\n".utf8).write(to: a)
        XCTAssertThrowsError(try EmlxParser.readMessageID(atPath: a.path))
        let b = store.root.appendingPathComponent("bad2.emlx")
        try Data(repeating: 0x31, count: 10_000).write(to: b)   // no newline at all
        XCTAssertThrowsError(try EmlxParser.readMessageID(atPath: b.path))
        let c = store.root.appendingPathComponent("empty.emlx")
        try Data().write(to: c)
        XCTAssertThrowsError(try EmlxParser.readMessageID(atPath: c.path))
    }
}
