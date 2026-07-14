import XCTest
@testable import MailSQLite

/// #183 + #238 — part-id-directory probing and the not-downloaded signal.
///
/// #183 (live-proven on message 274368): Mail writes the external attachment
/// cache under its OWN, often-degraded rendition of the filename (`麻煩老師…`
/// → `??????…` plus whitespace drift), while our parser reads the correct
/// MIME-header name — so the byte-for-byte name match misses and `savable`
/// reports a false negative. The on-disk part directory, however, equals the
/// Envelope Index `attachment_id`, giving a name-free deterministic probe.
///
/// #238: a `.partial.emlx` part whose body was never fetched carries
/// `X-Apple-Content-Length` headers with an EMPTY body — a detectable
/// "not downloaded" marker, distinct from "not extractable".
final class AttachmentPartIdProbeTests: XCTestCase {

    private var tempRoot: URL!
    private let rowId = 262653  // hash path 2/6/2 (matches sibling suite)
    private let accountUUID = "ABCE3A85-06BE-43BC-9B84-2CA6F325612F"
    private let storeUUID = "5FCC6F13-2CE3-48B1-907D-686244C0229A"

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("partid-probe-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        EnvelopeIndexReader.mailStoragePathOverride = nil
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    /// The correct MIME-header filename (what our parser and the caller see).
    private let mimeName = "115暑心測研進度表(補充一)1150507(麻煩老師填寫115暑上課進度講次).pdf"
    /// Mail's degraded on-disk rendition (?-substituted + whitespace drift).
    private let diskName = "115暑心測研進度表(補充一)1150507 (??????115? 上課進度講次).pdf"

    private func makeMessage(withPlaceholder placeholder: Bool) -> String {
        let placeholderHeaders = placeholder
            ? "Content-Transfer-Encoding: BASE64\r\nX-Apple-Content-Length: 368896\r\n"
            : "Content-Transfer-Encoding: BASE64\r\n"
        return "From: a@b.c\r\n"
            + "Subject: t\r\n"
            + "Mime-Version: 1.0\r\n"
            + "Content-Type: multipart/mixed; boundary=\"BB\"\r\n"
            + "\r\n"
            + "--BB\r\n"
            + "Content-Type: text/plain\r\n"
            + "\r\n"
            + "body text\r\n"
            + "--BB\r\n"
            + "Content-Type: application/pdf; name=\"\(mimeName)\"\r\n"
            + "Content-Disposition: attachment; filename=\"\(mimeName)\"\r\n"
            + placeholderHeaders
            + "\r\n"
            + "\r\n"
            + "--BB--\r\n"
    }

    /// Install a fake V10 tree with a `.partial.emlx` for `rowId` and,
    /// optionally, the external cache file under part dir `partId`.
    /// Returns the mailboxURL for the resolver.
    private func install(placeholder: Bool, externalPartId: String?) throws -> String {
        let mailV10 = tempRoot.appendingPathComponent("Library/Mail/V10", isDirectory: true)
        let hashDir = mailV10
            .appendingPathComponent(accountUUID)
            .appendingPathComponent("INBOX.mbox")
            .appendingPathComponent(storeUUID)
            .appendingPathComponent("Data/2/6/2", isDirectory: true)
        let messagesDir = hashDir.appendingPathComponent("Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messagesDir, withIntermediateDirectories: true)

        let message = makeMessage(withPlaceholder: placeholder)
        let messageData = Data(message.utf8)
        var emlx = Data("\(messageData.count)\n".utf8)
        emlx.append(messageData)
        emlx.append(Data("<?xml version=\"1.0\"?><plist><dict/></plist>".utf8))
        try emlx.write(to: messagesDir.appendingPathComponent("\(rowId).partial.emlx"))

        if let partId = externalPartId {
            let partDir = hashDir
                .appendingPathComponent("Attachments", isDirectory: true)
                .appendingPathComponent("\(rowId)", isDirectory: true)
                .appendingPathComponent(partId, isDirectory: true)
            try FileManager.default.createDirectory(at: partDir, withIntermediateDirectories: true)
            try Data("PDFBYTES-ground-truth".utf8)
                .write(to: partDir.appendingPathComponent(diskName))
        }

        EnvelopeIndexReader.mailStoragePathOverride = mailV10.path
        return "ews://\(accountUUID)/INBOX"
    }

    // MARK: #183 — part-id probe rescues the degraded-name false negative

    func testSavabilityDetail_degradedDiskName_partIdProbeReportsSavable() throws {
        let mailboxURL = try install(placeholder: true, externalPartId: "2")
        let detail = try EmlxParser.attachmentSavabilityDetail(
            rowId: rowId, mailboxURL: mailboxURL, partIds: [mimeName: "2"])
        let entry = try XCTUnwrap(detail[mimeName])
        XCTAssertTrue(entry.savable,
                      "part-id probe must rescue the name-mismatch false negative (#183)")
        XCTAssertNil(entry.reason)
    }

    func testSavabilityDetail_withoutPartIds_nameMismatchStaysFalse_reasonNotDownloaded() throws {
        let mailboxURL = try install(placeholder: true, externalPartId: nil)
        let detail = try EmlxParser.attachmentSavabilityDetail(
            rowId: rowId, mailboxURL: mailboxURL, partIds: [:])
        let entry = try XCTUnwrap(detail[mimeName])
        XCTAssertFalse(entry.savable)
        XCTAssertEqual(entry.reason, .notDownloaded,
                       "X-Apple-Content-Length + empty body = not fetched from the server (#238)")
    }

    func testSavabilityDetail_noPlaceholder_reasonNotExtractable() throws {
        let mailboxURL = try install(placeholder: false, externalPartId: nil)
        let detail = try EmlxParser.attachmentSavabilityDetail(
            rowId: rowId, mailboxURL: mailboxURL, partIds: [:])
        let entry = try XCTUnwrap(detail[mimeName])
        XCTAssertFalse(entry.savable)
        XCTAssertEqual(entry.reason, .notExtractable)
    }

    func testLegacySavability_shapeUnchanged() throws {
        let mailboxURL = try install(placeholder: true, externalPartId: nil)
        let savability = try EmlxParser.attachmentSavability(
            rowId: rowId, mailboxURL: mailboxURL)
        XCTAssertEqual(savability[mimeName], false)
    }

    // MARK: #183 — extraction via the part-id directory

    func testAttachmentData_partIdFallback_returnsDiskBytes() throws {
        let mailboxURL = try install(placeholder: true, externalPartId: "2")
        let data = try EmlxParser.attachmentData(
            rowId: rowId, mailboxURL: mailboxURL,
            attachmentName: mimeName, partId: "2")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "PDFBYTES-ground-truth",
                       "the single file in Attachments/<rowId>/<partId>/ is the attachment (#183)")
    }

    // MARK: #238 — distinct not-downloaded error

    func testAttachmentData_notDownloaded_throwsActionableError() throws {
        let mailboxURL = try install(placeholder: true, externalPartId: nil)
        XCTAssertThrowsError(try EmlxParser.attachmentData(
            rowId: rowId, mailboxURL: mailboxURL,
            attachmentName: mimeName, partId: "2")) { error in
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(msg.contains("not downloaded") || msg.contains("Download attachments"),
                          "must be the distinct not-downloaded guidance, not 'not found': \(msg)")
        }
    }
}

// MARK: #183 verify REQUIRED — hidden-file / symlink hardening

extension AttachmentPartIdProbeTests {

    func testPartIdProbe_ignoresDSStore_stillFindsTheAttachment() throws {
        // Finder creates .DS_Store the moment a user browses the Attachments
        // dir — the probe must filter hidden files, not bail on count != 1.
        let mailboxURL = try install(placeholder: true, externalPartId: "2")
        let partDir = tempRoot.appendingPathComponent(
            "Library/Mail/V10/\(accountUUID)/INBOX.mbox/\(storeUUID)/Data/2/6/2/Attachments/\(rowId)/2")
        try Data("junk".utf8).write(to: partDir.appendingPathComponent(".DS_Store"))
        let data = try EmlxParser.attachmentData(
            rowId: rowId, mailboxURL: mailboxURL,
            attachmentName: mimeName, partId: "2")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "PDFBYTES-ground-truth")
    }

    func testPartIdProbe_lonelyDotfile_isNotAnAttachment() throws {
        // A part dir whose ONLY entry is hidden metadata must not be treated
        // as the attachment (wrong-bytes tail of the verify finding).
        let mailboxURL = try install(placeholder: true, externalPartId: nil)
        let partDir = tempRoot.appendingPathComponent(
            "Library/Mail/V10/\(accountUUID)/INBOX.mbox/\(storeUUID)/Data/2/6/2/Attachments/\(rowId)/2")
        try FileManager.default.createDirectory(at: partDir, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: partDir.appendingPathComponent(".DS_Store"))
        XCTAssertThrowsError(try EmlxParser.attachmentData(
            rowId: rowId, mailboxURL: mailboxURL,
            attachmentName: mimeName, partId: "2"))
    }

    func testPartIdProbe_symlinkEntry_rejected() throws {
        let mailboxURL = try install(placeholder: true, externalPartId: nil)
        let partDir = tempRoot.appendingPathComponent(
            "Library/Mail/V10/\(accountUUID)/INBOX.mbox/\(storeUUID)/Data/2/6/2/Attachments/\(rowId)/2")
        try FileManager.default.createDirectory(at: partDir, withIntermediateDirectories: true)
        let target = tempRoot.appendingPathComponent("outside-secret.txt")
        try Data("SECRET".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: partDir.appendingPathComponent("link.pdf"), withDestinationURL: target)
        XCTAssertThrowsError(try EmlxParser.attachmentData(
            rowId: rowId, mailboxURL: mailboxURL,
            attachmentName: mimeName, partId: "2"),
            "a symlink lone entry must be rejected, never followed")
    }
}
