import XCTest
@testable import MailSQLite

/// #274 — partial `.emlx` visibility. Mail stores a not-yet-downloaded
/// message body as `<rowid>.partial.emlx`; `resolveEmlxPath` transparently
/// fell back to it and `readEmail` parsed the header-only file into a
/// "successful" empty-body result, so `get_email` never triggered its
/// AppleScript fallback (which is what nudges Mail to fetch the body).
/// These tests pin the new `isPartial` visibility at the parser layer.
final class PartialEmlxTests: XCTestCase {

    private struct Fixture {
        let mailboxURL: String
        let messagesDir: URL
        let cleanup: () -> Void
    }

    /// Build a fake V10 store; returns the mailbox URL + Messages dir.
    private func makeStore() throws -> Fixture {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(
            "partial-emlx-fixture-\(UUID().uuidString)", isDirectory: true
        )
        let mailV10 = tmp.appendingPathComponent("Library/Mail/V10", isDirectory: true)
        let accountUUID = "ABCE3A85-06BE-43BC-9B84-2CA6F325612F"
        let storeUUID = "5FCC6F13-2CE3-48B1-907D-686244C0229A"
        let messagesDir = mailV10
            .appendingPathComponent(accountUUID)
            .appendingPathComponent("INBOX.mbox")
            .appendingPathComponent(storeUUID)
            .appendingPathComponent("Data/Messages", isDirectory: true)
        try fm.createDirectory(at: messagesDir, withIntermediateDirectories: true)

        let originalBase = EnvelopeIndexReader.mailStoragePathOverride
        EnvelopeIndexReader.mailStoragePathOverride = mailV10.path
        return Fixture(
            mailboxURL: "imap://\(accountUUID)/INBOX",
            messagesDir: messagesDir,
            cleanup: {
                EnvelopeIndexReader.mailStoragePathOverride = originalBase
                try? fm.removeItem(at: tmp)
            }
        )
    }

    /// Full message: headers + blank line + body (emlx length-prefix format).
    private func writeFullEmlx(rowId: Int, in dir: URL) throws {
        let message = "From: a@x.co\r\nSubject: full\r\n\r\nhello body\r\n"
        let payload = "\(message.utf8.count)\n\(message)"
        try payload.data(using: .utf8)!.write(to: dir.appendingPathComponent("\(rowId).emlx"))
    }

    /// Partial message: headers only, no body — what Mail leaves on disk
    /// before the body is downloaded.
    private func writePartialEmlx(rowId: Int, in dir: URL) throws {
        let message = "From: a@x.co\r\nSubject: partial\r\n"
        let payload = "\(message.utf8.count)\n\(message)"
        try payload.data(using: .utf8)!.write(to: dir.appendingPathComponent("\(rowId).partial.emlx"))
    }

    // MARK: - resolveEmlxPathDetailed

    func testDetailed_partialOnly_reportsPartial() throws {
        let fx = try makeStore(); defer { fx.cleanup() }
        try writePartialEmlx(rowId: 42, in: fx.messagesDir)

        let r = EmlxParser.resolveEmlxPathDetailed(rowId: 42, mailboxURL: fx.mailboxURL)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.isPartial, true)
        XCTAssertTrue(r?.path.hasSuffix("/42.partial.emlx") ?? false)
    }

    func testDetailed_fullOnly_notPartial() throws {
        let fx = try makeStore(); defer { fx.cleanup() }
        try writeFullEmlx(rowId: 43, in: fx.messagesDir)

        let r = EmlxParser.resolveEmlxPathDetailed(rowId: 43, mailboxURL: fx.mailboxURL)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.isPartial, false)
        XCTAssertTrue(r?.path.hasSuffix("/43.emlx") ?? false)
    }

    func testDetailed_bothPresent_prefersFull() throws {
        // Mail downloaded the body: the full .emlx lands next to (or in place
        // of) the partial one — the full file must win.
        let fx = try makeStore(); defer { fx.cleanup() }
        try writeFullEmlx(rowId: 44, in: fx.messagesDir)
        try writePartialEmlx(rowId: 44, in: fx.messagesDir)

        let r = EmlxParser.resolveEmlxPathDetailed(rowId: 44, mailboxURL: fx.mailboxURL)
        XCTAssertEqual(r?.isPartial, false)
        XCTAssertTrue(r?.path.hasSuffix("/44.emlx") ?? false)
    }

    func testDetailed_missing_returnsNil() throws {
        let fx = try makeStore(); defer { fx.cleanup() }
        XCTAssertNil(EmlxParser.resolveEmlxPathDetailed(rowId: 45, mailboxURL: fx.mailboxURL))
    }

    /// The legacy String? wrapper must stay byte-compatible.
    func testLegacyResolve_matchesDetailedPath() throws {
        let fx = try makeStore(); defer { fx.cleanup() }
        try writePartialEmlx(rowId: 46, in: fx.messagesDir)
        XCTAssertEqual(
            EmlxParser.resolveEmlxPath(rowId: 46, mailboxURL: fx.mailboxURL),
            EmlxParser.resolveEmlxPathDetailed(rowId: 46, mailboxURL: fx.mailboxURL)?.path
        )
    }

    // MARK: - readEmail partial visibility

    func testReadEmail_fromPartial_flagsPartialAndEmptyBody() throws {
        let fx = try makeStore(); defer { fx.cleanup() }
        try writePartialEmlx(rowId: 47, in: fx.messagesDir)

        let content = try EmlxParser.readEmail(rowId: 47, mailboxURL: fx.mailboxURL, format: "text")
        XCTAssertTrue(content.fromPartialEmlx)
        XCTAssertNil(content.textBody)
        XCTAssertNil(content.htmlBody)
        XCTAssertEqual(content.subject, "partial")
    }

    func testReadEmail_fromFull_notFlagged() throws {
        let fx = try makeStore(); defer { fx.cleanup() }
        try writeFullEmlx(rowId: 48, in: fx.messagesDir)

        let content = try EmlxParser.readEmail(rowId: 48, mailboxURL: fx.mailboxURL, format: "text")
        XCTAssertFalse(content.fromPartialEmlx)
        XCTAssertEqual(content.textBody?.contains("hello body"), true)
    }
}
